(* Utility program which copies between two block devices, using vhd BATs and efficient zero-scanning
   for performance. *)

open Pervasiveext
open Stringext
open Listext

let ( +* ) = Int64.add
let ( -* ) = Int64.sub
let ( ** ) = Int64.mul

let kib = 1024L
let mib = kib ** kib

let blocksize = 10L ** mib

exception ShortWrite of int (* offset *) * int (* expected *) * int (* actual *)

(* Consider a tunable quantum of non-zero'ness such that if we encounter
   a non-zero, we know we're going to incur the penalty of a seek/write
   and we may as well write a sizeable chunk at a time. *)
let roundup x = 
	let quantum = 16384 in
	((x + quantum + quantum - 1) / quantum) * quantum

(** The copying routine can operate on anything which looks like a file-descriptor/Stream *)
module type Stream = sig
	type stream
	val read: stream -> int64 -> string -> int -> int -> unit
	val write: stream -> int64 -> string -> int -> int -> int
end

(* [fold_over_blocks (s, len) skip f initial] applies contiguous (start, length) pairs to 
   [f] starting at [s] up to maximum length [len] where each pair is as large as possible
   up to [skip]. *)
let fold_over_blocks (s, len) skip f initial = 
	let rec inner offset acc = 
		if offset = s +* len then acc
		else
			let len' = min skip (s +* len -* offset) in
			inner (offset +* len') (f acc (offset, len')) in
	inner s initial

(** Represents a "block allocation table" *)
module Bat = ExtentlistSet.ExtentlistSet(Int64)

(** As we copy we accumulate some simple performance stats *)
type stats = {
	writes: int;  (* total number of writes *)
	bytes: int64; (* total bytes written *)
}

(** Perform the data duplication ("DD") *)
module DD(S : Stream) = struct
	(** [copy progress_cb bat sparse src dst size] copies blocks of data from [src] to [dst]
	    where [bat] represents the allocated / dirty blocks in [src];
	    where if sparse is None it means don't scan for and skip over blocks of zeroes in [src]
	    where if sparse is (Some c) it means do scan for and skip over blocks of 'c' in [src]
	    while calling [progress_cb] frequently to report the fraction complete
	*)
	let copy progress_cb bat sparse (src: S.stream) (dst: S.stream) size = 
		let buf = String.create (Int64.to_int blocksize) in
		let do_block stats (offset, this_chunk) : stats =
			progress_cb ((Int64.to_float offset) /. (Int64.to_float size));   
			S.read src offset buf 0 (Int64.to_int this_chunk);
			let write_extent stats (s, e) = 
				let n = S.write dst (offset +* (Int64.of_int s)) buf s e in
				if n < e then raise (ShortWrite(s, e, n));
				{ stats with writes = stats.writes + 1; bytes = stats.bytes +* (Int64.of_int n) }
			in
			begin match sparse with
			| Some zero -> Zerocheck.fold_over_nonzeros buf (Int64.to_int this_chunk) roundup write_extent stats
			| None -> write_extent stats (0, Int64.to_int this_chunk)
			end in
		(* For each entry from the BAT, copy it as a sequence of sub-blocks *)
		Bat.fold_left (fun stats b -> fold_over_blocks b blocksize do_block stats) { writes = 0; bytes = 0L } bat
end

(* Helper function to always return a block of zeroes, like /dev/null *)
let read_zeroes _ _ buf offset len = 
	for i = 0 to len - 1 do
		buf.[offset + i] <- '\000'
	done

(** A Stream interface implemented over strings, useful for testing *)
module String_stream = struct
	type stream = string
	let blit src srcoff dst dstoff len = 
		(* Printf.printf "[%s](%d) -> [%s](%d) %d\n" "?" srcoff "?" dstoff len; *)
		String.blit src srcoff dst dstoff len
	let read str stream_offset buf offset len = 
		blit str (Int64.to_int stream_offset) buf offset len
	let write str stream_offset buf offset len = 
		blit buf offset str (Int64.to_int stream_offset) len;
		len
end

(** A File interface implemented over open Unix files *)
module File_stream = struct
	type stream = Unix.file_descr
		
	let read stream stream_offset buf offset len = 
		Unix.LargeFile.lseek stream stream_offset Unix.SEEK_SET; 
		Unixext.really_read stream buf offset len 
	let write stream stream_offset buf offset len = 
		let newoff = Unix.LargeFile.lseek stream stream_offset Unix.SEEK_SET in
		(* Printf.printf "Unix.write buf len %d; offset %d; len %d\n" (String.length buf) offset len; *)
		Unix.write stream buf offset len
end

(** An implementation of the DD algorithm over strings *)
module String_copy = DD(String_stream)

(** An implementatino of the DD algorithm which copies zeroes into strings *)
module String_write_zero = DD(struct
	include String_stream
	let read = read_zeroes
end)

(** An implementatino of the DD algorithm over Unix files *)
module File_copy = DD(File_stream)

(** An implementatin of the DD algorithm which copies zeroes into files *)
module File_write_zero = DD(struct
	include File_stream
	let read = read_zeroes
end)

(** [file_dd ?progress_cb ?size ?bat prezeroed src dst]
    If [size] is not given, will assume a plain file and will use st_size from Unix.stat.
    If [prezeroed] is false, will first explicitly write zeroes to all blocks not in [bat].
    Will then write blocks from [src] into [dst], using the [bat]. If [prezeroed] will additionally
    scan for zeroes within the allocated blocks. *)     
let file_dd ?(progress_cb = (fun _ -> ())) ?size ?bat prezeroed src dst = 
	let size = match size with
	| None -> (Unix.LargeFile.stat src).Unix.LargeFile.st_size 
	| Some x -> x in
	let ifd = Unix.openfile src [ Unix.O_RDONLY ] 0o600 in
	let ofd = Unix.openfile dst [ Unix.O_WRONLY; Unix.O_CREAT ] 0o600 in
 	(* Make sure the output file has the right size *)
	Unix.LargeFile.lseek ofd (size -* 1L) Unix.SEEK_SET;
	Unix.write ofd "\000" 0 1;
	Unix.LargeFile.lseek ofd 0L Unix.SEEK_SET;
	let full_bat = Bat.of_list [0L, size] in
	let empty_bat = Bat.of_list [] in
	let bat = Opt.default full_bat bat in
	(* If not prezeroed then: 
	   1. explicitly write zeroes into the complement of the BAT;
	   2. don't scan and skip zeroes in the source disk *)
	let bat' = if prezeroed
	then empty_bat
	else Bat.difference full_bat bat in	
	let progress_cb_zero, progress_cb_copy = 
		(fun fraction -> progress_cb (0.5 *. fraction)),
		(fun fraction -> progress_cb (0.5 *. fraction +. 0.5)) in
	Printf.printf "Wiping\n";
	File_write_zero.copy progress_cb_zero bat' None ifd ofd size;
	Printf.printf "Copying\n";
	File_copy.copy progress_cb_copy bat (if prezeroed then Some '\000' else None) ifd ofd size

(** [make_random size zero nonzero] returns a string (of size [size]) and a BAT. Blocks not in the BAT
    are guaranteed to be [zero]. Blocks in the BAT are randomly either [zero] or [nonzero]. *)
let make_random size zero nonzero = 
	(* First make a random BAT *)
	let bs = size / 100 in
	let bits = Array.make ((size + bs - 1) / bs) false in
	for i = 0 to Array.length bits - 1 do
		bits.(i) <- Random.bool ()
	done;
	let result = String.create size in
	for i = 0 to size - 1 do
		if bits.(i / bs)
		then result.[i] <- (if Random.float 10. > 1.0 then zero else nonzero)
		else result.[i] <- zero
	done;
	let bat = snd (Array.fold_left (fun (offset, acc) bit -> 
		let offset' = min size (offset + bs) in
		offset', if bit then (offset, offset' - offset) :: acc else acc) (0, []) bits) in
	let bat = Bat.of_list (List.map (fun (x, y) -> Int64.of_int x, Int64.of_int y) bat) in
	result, bat

(** [test_dd (input, bat) ignore_bat prezeroed zero nonzero] uses the DD algorithm to make a copy of
    the string [input]. 
    If [ignore_bat] is true then the [bat] is ignored (as if none were available).
    If [prezeroed] is true then the output is created full of [zero], otherwise [nonzero].
    The resulting string is compared to the original and if not idential, an exception is raised.
 *)
let test_dd (input, bat) ignore_bat prezeroed zero nonzero = 
	let size = String.length input in
	let output = String.make size (if prezeroed then zero else nonzero) in
	try

		let full_bat = Bat.of_list [0L, Int64.of_int size] in
		let empty_bat = Bat.of_list [] in
		let bat = if ignore_bat then full_bat else bat in
		(* If not prezeroed then: 
		   1. explicitly write zeroes into the complement of the BAT;
		   2. don't scan and skip zeroes in the source disk *)
		let bat' = if prezeroed
		then empty_bat
		else Bat.difference full_bat bat in	
		String_write_zero.copy (fun _ -> ()) bat' None input output (Int64.of_int size);
		let stats = String_copy.copy (fun _ -> ()) bat (if prezeroed then Some zero else None) input output (Int64.of_int size) in
		assert (String.compare input output = 0);
		stats
	with e ->
		Printf.printf "Exception: %s" (Printexc.to_string e);
		let make_visible x = 
			for i = 0 to String.length x - 1 do
				if x.[i] = '\000' 
				then x.[i] <- 'z'
				else x.[i] <- 'a';
			done in
		make_visible input;
		make_visible output;
		failwith (Printf.sprintf "input = [%s]; output = [%s]" input output)

(** Generates lots of random strings and makes copies with the DD algorithm, checking that the copies are identical *)
let test_lots_of_strings () =
	let n = 1000 and m = 1000 in
	let writes = ref 0 and bytes = ref 0L in
	for i = 0 to n do
		if i mod 100 = 0 then (Printf.printf "i = %d\n" i; flush stdout);
		List.iter (fun ignore_bat ->
			List.iter (fun prezeroed ->
				let stats = test_dd (make_random m '\000' 'a') ignore_bat prezeroed '\000' 'a' in
				writes := !writes + stats.writes;
				bytes := !bytes +* stats.bytes
			) [ true; false ]
		) [ true; false ]
	done;
	Printf.printf "Tested %d random strings of length %d using all 4 combinations of ignore_bat, prezeroed\n" n m;
	Printf.printf "Total writes: %d\n" !writes;
	Printf.printf "Total bytes: %Ld\n" !bytes

(** [vhd_of_device path] returns (Some vhd) where 'vhd' is the vhd leaf backing a particular device [path] or None.
    [path] may either be a blktap2 device *or* a blkfront device backed by a blktap2 device. If the latter then
    the script must be run in the same domain as blkback. *)
let vhd_of_device path =
	let find_underlying_tapdisk path =
		try 
		(* If we're looking at a xen frontend device, see if the backend
		   is in the same domain. If so check if it looks like a .vhd *)
			let rdev = (Unix.stat path).Unix.st_rdev in
			let major = rdev / 256 and minor = rdev mod 256 in
			let link = Unix.readlink (Printf.sprintf "/sys/dev/block/%d:%d/device" major minor) in
			match List.rev (String.split '/' link) with
			| id :: "xen" :: "devices" :: _ when String.startswith "vbd-" id ->
				let id = int_of_string (String.sub id 4 (String.length id - 4)) in
				let xs = Xs.domain_open () in
				finally
				(fun () ->
					let self = xs.Xs.read "domid" in
					let backend = xs.Xs.read (Printf.sprintf "device/vbd/%d/backend" id) in
					let params = xs.Xs.read (Printf.sprintf "%s/params" backend) in
					match String.split '/' backend with
					| "local" :: "domain" :: bedomid :: _ ->
						assert (self = bedomid);
						Some params
					| _ -> raise Not_found
				)
				(fun () -> Xs.close xs)
			| _ -> raise Not_found
		with _ -> None in
	let tapdisk_of_path path =
		try 
			match Tapctl.of_device (Tapctl.create ()) path with
			| _, _, (Some (_, vhd)) -> Some vhd
			| _, _, _ -> raise Not_found
		with Not_found -> None in
	match tapdisk_of_path path with
	| Some vhd -> Some vhd
	| None ->
		begin match find_underlying_tapdisk path with
		| Some path ->
			begin match tapdisk_of_path path with
			| Some vhd -> Some vhd
			| None -> None
			end
		| None -> None
		end

(** Given a vhd filename, return the BAT *)
let bat vhd = 
	let h = Vhd._open vhd [ Vhd.Open_rdonly ] in
	finally
	(fun () -> 
		let b = Vhd.get_bat h in
		let b' = List.map_tr (fun (s, l) -> 2L ** mib ** (Int64.of_int s), 2L ** mib ** (Int64.of_int l)) b in
		Bat.of_list b')
	(fun () -> Vhd.close h)

(* Record when the binary started for performance measuring *)
let start = Unix.gettimeofday ()

(* Set to true when we want machine-readable output *)
let machine_readable = ref false 

(* Helper function to print nice progress info *)
let progress_cb =
	let last_percent = ref (-1) in

	function fraction ->
		let new_percent = int_of_float (fraction *. 100.) in
		if !last_percent <> new_percent then begin
			if !machine_readable
			then Printf.printf "Progress: %.0f\n" (fraction *. 100.)
			else Printf.printf "\b\rProgress: %-60s (%d%%)" (String.make (int_of_float (fraction *. 60.)) '#') new_percent;
			flush stdout;
		end;
		last_percent := new_percent

let _ = 
	let base = ref "" and src = ref "" and dest = ref "" and size = ref (-1L) and prezeroed = ref false and test = ref false in
	Arg.parse [ "-base", Arg.Set_string base, "base disk to search for differences from (default: None)";
		    "-src", Arg.Set_string src, "source disk";
		    "-dest", Arg.Set_string dest, "destination disk";
		    "-size", Arg.String (fun x -> size := Int64.of_string x), "number of bytes to copy";
		    "-prezeroed", Arg.Set prezeroed, "assume the destination disk has been prezeroed";
		    "-machine", Arg.Set machine_readable, "emit machine-readable output";
		    "-test", Arg.Set test, "perform some unit tests"; ]
	(fun x -> Printf.fprintf stderr "Warning: ignoring unexpected argument %s\n" x)
	(String.concat "\n" [ "Usage:";
			      Printf.sprintf "%s [-base x] [-prezeroed] <-src y> <-dest z> <-size s>" Sys.argv.(0);
			      "  -- copy <s> bytes from <y> to <z>. If <-base x> is specified then only copy differences";
			      "     between <x> and <y>. If [-base x] is unspecified and [-prezeroed] is unspecified ";
			      "     then assume the destination must be fully wiped.";
			      "";
			      "Examples:";
			      "";
			      Printf.sprintf "%s -prezeroed      -src /dev/xvda -dest /dev/xvdb -size 1024" Sys.argv.(0);
			      "  -- copy 1024 bytes from /dev/xvda to /dev/xvdb assuming that /dev/xvdb is completely";
			      "     full of zeroes so there's no need to explicitly copy runs of zeroes.";
			      "";
			      Printf.sprintf "%s                 -src /dev/xvda -dest /dev/xvdb -size 1024" Sys.argv.(0);
			      "";
			      "  -- copy 1024 bytes from /dev/xvda to /dev/xvdb, always explicitly writing zeroes";
			      "     into /dev/xvdb under the assumption that it contains undefined data.";
			      "";
			      Printf.sprintf "%s -base /dev/xvdc -src /dev/xvda -dest /dev/xvdb -size 1024" Sys.argv.(0);
			      "";
			      " -- copy up to 1024 bytes of *differences* between /dev/xvdc and /dev/xvda into";
			      "     into /dev/xvdb under the assumption that /dev/xvdb contains identical data";
			      "     to /dev/xvdb."; ]);
 	if !test then begin
		test_lots_of_strings ();
		exit 0
	end;
	if !src = "" || !dest = "" || !size = (-1L) then begin
		Printf.fprintf stderr "Must have -src -dest and -size arguments\n";
		exit 1;
	end;


        let size = Some !size in
	let src_vhd = vhd_of_device !src and dest_vhd = vhd_of_device !dest in
	Printf.printf "auto-detect src vhd:  %s\n" (Opt.default "None" (Opt.map (fun x -> "Some " ^ x) src_vhd));
	let src_bat = Opt.map bat src_vhd in 
	progress_cb 0.;
	let stats = file_dd ~progress_cb ?size ?bat:src_bat !prezeroed !src !dest in
	Printf.printf "Time: %.2f seconds\n" (Unix.gettimeofday () -. start);
	Printf.printf "\nNumber of writes: %d\n" stats.writes;
	Printf.printf "Number of bytes: %Ld\n" stats.bytes
