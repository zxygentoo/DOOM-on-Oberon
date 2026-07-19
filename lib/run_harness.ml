(* Shared plumbing for the emulator harnesses (run_blob / run_dsk): CLI failure,
   whole-file reads, the write-only UART shape, and the PGM frame dump — the
   pixel-format-critical encoding (fb bottom-up, bit 0 leftmost) stated once, so
   the harness legs cannot diverge on it. *)

module M = Emu.Risc

let fail fmt =
  Printf.ksprintf
    (fun s ->
       prerr_endline s;
       exit 1)
    fmt
;;

let read_file path =
  try In_channel.with_open_bin path In_channel.input_all with
  | Sys_error e -> fail "%s" e
;;

(* a write-only UART: tx always ready (status bit 1), rx never *)
let tx_serial write_byte =
  { Emu.Io.serial_read_status = (fun () -> 2)
  ; serial_read_data = (fun () -> 0)
  ; serial_write_data = write_byte
  }
;;

(* PGM P5: fb bottom-up flipped so the file reads top-down, bit 0 leftmost;
   geometry comes from the machine itself (Risc.fb_width/fb_height). Rows are
   staged in one buffer — a per-pixel output_char costs real time at 786k px. *)
let dump_frame m path =
  let words = M.fb_width m
  and lines = M.fb_height m in
  let row = Bytes.create (32 * words) in
  Out_channel.with_open_bin path (fun oc ->
    Printf.fprintf oc "P5\n%d %d\n255\n" (32 * words) lines;
    for y = 0 to lines - 1 do
      let line = lines - 1 - y in
      for wx = 0 to words - 1 do
        let w = M.framebuffer_word m ((line * words) + wx) in
        for bit = 0 to 31 do
          Bytes.set
            row
            ((32 * wx) + bit)
            (if (w lsr bit) land 1 = 1 then '\255' else '\000')
        done
      done;
      Out_channel.output_bytes oc row
    done)
;;
