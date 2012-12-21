open Word
open MessagesDef
open Unix
open Printf
open Openflow1_0

type switchId = Word32.t

module type PLATFORM = sig

  exception SwitchDisconnected of switchId

  val send_to_switch : switchId -> xid -> message -> unit

  val recv_from_switch : switchId -> xid * message

  val accept_switch : unit -> switchId

end

module type FD = sig
  val fd : file_descr
end

let string_of_sockaddr (sa : sockaddr) : string = match sa with
  | ADDR_UNIX str -> str
  | ADDR_INET (addr,port) -> string_of_inet_addr addr ^ string_of_int port

(* TODO(arjun): awful performance--how do I use the newer cstruct on Github? *)
let ba_of_string (str : string) : Cstruct.buf = 
  let open Bigarray in
  let len = String.length str in
  let ba = Array1.create char c_layout len in
  for i = 0 to len do
    Array1.set ba i (String.get str i)
  done;
  ba
   
module ActualPlatform (Server : FD): PLATFORM = struct

  exception SwitchDisconnected of switchId
  exception UnknownSwitch of switchId

  let switch_fds : (switchId, file_descr) Hashtbl.t = Hashtbl.create 100

  let fd_of_switch_id (switch_id : switchId) : file_descr = 
    try 
      Hashtbl.find switch_fds switch_id 
    with Not_found -> raise (UnknownSwitch switch_id)

  let disconnect_switch (sw_id : switchId) = 
    try 
      let fd = Hashtbl.find switch_fds sw_id in
      close fd;
      Hashtbl.remove switch_fds sw_id        
    with Not_found ->
      eprintf "[disconnect_switch] switch not found\n%!";
      raise (UnknownSwitch sw_id)

  let accept_switch () = 
    let (fd, sa) = accept Server.fd in
    eprintf "[accept_switch] : %s connected\n%!" (string_of_sockaddr sa);
    Word32.from_int32 0l

  let recv_from_switch (sw_id : switchId) : xid * message = 
    let switch_fd = fd_of_switch_id sw_id in
    let ofhdr_str = String.create sizeof_ofp_header in
    let bytes_read = read switch_fd ofhdr_str 0 sizeof_ofp_header in
    if bytes_read <> sizeof_ofp_header then
      begin
        eprintf "[recv_from_switch] not enough bytes read\n%!";
        disconnect_switch sw_id;
        raise (SwitchDisconnected sw_id)
      end;
    let hdr = Header.parse (ba_of_string ofhdr_str) in
    let sizeof_body = hdr.Header.len - sizeof_ofp_header in
    let body_str = String.create sizeof_body in
    let bytes_read = read switch_fd body_str 0 sizeof_body in
    if bytes_read <> sizeof_body then
      begin 
        eprintf "[recv_from_switch] not enough bytes read from body\n%!";
        disconnect_switch sw_id;
        raise (SwitchDisconnected sw_id)
      end;
    Message.parse hdr (ba_of_string body_str)

  let send_to_switch (sw_id : switchId) (xid : xid) (msg : message) : unit = 
    let fd = fd_of_switch_id sw_id in
    let out = Message.marshal xid msg in
    let len = String.length out in
    let n = write fd out 0 len in
    if n <> len then
      begin
        eprintf "[send_to_switch] not enough bytes written\n%!";
        disconnect_switch sw_id;
        raise (SwitchDisconnected sw_id)
      end;
    ()
      
end


    
