open Extras

type system = Coq | Matita | Pvs | Lean | Hollight | OpenTheory

(** Signature of an exporter for a system. Supporting a new system amounts to
    provide an implementation to EXP for the new system. *)
module type EXP = sig
  val print_ast : out_channel -> Api.Env.t -> Ast.ast -> unit
  (** [print_ast oc env ast] prints STTfa [ast] to out channel [oc] in Dedukti
      environment [env]. It performs side effects or fails. *)
end

let exporter sys : (module EXP) =
  match sys with
  | Coq -> (module Coq)
  | Matita -> (module Matita)
  | Pvs -> (module Pvs)
  | Lean -> (module Lean)
  | Hollight -> (module Hollight)
  | OpenTheory -> (module Opentheory)

type ('a, 'b) register_eq =
  'a Api.Processor.t * 'b Api.Processor.t ->
  ('a Api.Processor.t, 'b Api.Processor.t) Api.Processor.Registration.equal
  option

module SttfaCompile = struct
  (* NOTE the compiler works for one module only. *)
  type t = Ast.ast

  let items = ref []

  let handle_entry env entry =
    let modu = Api.Env.get_name env in
    items :=
      ( Compile.compile_entry env entry,
        Deps.dep_of_entry [ Sttfadk.sttfa_module; modu ] entry )
      :: !items

  let get_data env =
    let modu = Api.Env.get_name env in
    let items = List.rev !items in
    let dep = List.fold_left StrSet.union StrSet.empty (List.map snd items) in
    let items = List.map (fun i -> Result.get_ok (fst i)) items in
    Ast.{ md = Kernel.Basic.string_of_mident modu; dep; items }
end

type _ Api.Processor.t += SttfaCompile : Ast.ast Api.Processor.t

let equal_sttfacompile (type a b) : (a, b) register_eq = function
  | SttfaCompile, SttfaCompile ->
      Some (Api.Processor.Registration.Refl SttfaCompile)
  | _ -> None

let () =
  Api.Processor.Registration.register_processor SttfaCompile
    { equal = equal_sttfacompile }
    (module SttfaCompile)

let export ?(path = []) ?(oc = stdout) sys file =
  List.iter Api.Files.add_path path;
  let hook =
    Api.Processor.
      {
        before = (fun _ -> ());
        after =
          (fun env s ->
            (match s with
            | Some (env, lc, exn) -> Api.Env.fail_env_error env lc exn
            | None -> ());
            let (module Exporter) = exporter sys in
            let ast = SttfaCompile.get_data env in
            Exporter.print_ast oc env ast);
      }
  in
  ignore (Api.Processor.handle_files [ file ] ~hook SttfaCompile);
  Ok ()
