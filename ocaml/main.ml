open Printf
open Word
open Openflow1_0
open Platform
open Unix


module ServerFd : Platform.FD = struct
  let fd = socket PF_INET SOCK_STREAM 0
    
  let _ = 
    bind fd (ADDR_INET (inet_addr_any, 6633));
    listen fd 10
end

module Platform = ActualPlatform (ServerFd)
module Controller = DummyController.Make (Platform)

