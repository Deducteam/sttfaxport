(** This module aims to implement functions that trace reduction steps
    checking if two terms are convertible. *)

open Extras
open Ast
open Kernel.Basic
open Environ
module Dpp = Api.Pp.Default
module Reduction = Kernel.Reduction
open Result.Monad

let fast = ref false

let is_defined dkenv cst =
  let name = name_of cst in
  not (DkTools.is_static (Api.Env.get_signature dkenv) dloc name)

let rec is_redexable dkenv _te =
  match _te with
  | Cst (cst, _) -> is_defined dkenv cst
  | App (Abs _, _) -> true
  | App (f, _) -> is_redexable dkenv f
  | _ -> false

let rec get_app_redex dkenv side ctx tyf' =
  match tyf' with
  | App (Abs _, _te) -> (side, ctx, Beta tyf')
  | App (f, _) -> get_app_redex dkenv side (CAppL :: ctx) f
  | Cst (cst, _tys) ->
      assert (is_defined dkenv cst);
      (side, ctx, Delta (cst, _tys))
  | _ -> assert false

exception Equal
exception Maybe

let rec _get_beta_redex env ctx term =
  match term with
  | TeVar _ -> raise Not_found
  | Cst (_, _tys) -> raise Not_found
  | Abs (var, _ty, _te) ->
      let env' = add_te_var env var _ty in
      _get_beta_redex env' (CAbs :: ctx) _te
  | AbsTy (var, _te) ->
      let env' = add_ty_var env var in
      _get_beta_redex env' (CAbsTy :: ctx) _te
  | Forall (var, _ty, _te) ->
      let env' = add_te_var env var _ty in
      _get_beta_redex env' (CForall :: ctx) _te
  | Impl (_tel, _ter) -> (
      try _get_beta_redex env (CImplL :: ctx) _tel
      with Not_found -> _get_beta_redex env (CImplR :: ctx) _ter)
  | App (Abs _, _) -> (ctx, Beta term)
  | App (_tel, _ter) -> (
      try _get_beta_redex env (CAppL :: ctx) _tel
      with Not_found -> _get_beta_redex env (CAppR :: ctx) _ter)

let rec get_beta_redex env ctx term =
  match term with
  | Te term -> _get_beta_redex env ctx term
  | ForallP (var, term) ->
      let env' = add_ty_var env var in
      get_beta_redex env' (CForallP :: ctx) term

let get_beta_redex env ctx term =
  let ctx, redex = get_beta_redex env ctx term in
  (List.rev ctx, redex)

let _get_beta_redex env ctx term =
  let ctx, redex = _get_beta_redex env ctx term in
  (List.rev ctx, redex)

let rec _get_redex dkenv (envl, envr) ctx (left, right) =
  (* Format.eprintf "left:%a@." (print__te envl) left;
     Format.eprintf "right:%a@." (print__te envr) right; *)
  match (left, right) with
  | TeVar _, TeVar _ -> raise Equal
  | Cst (cst, _tys), Cst (cst', _tys') ->
      if is_defined dkenv cst then
        if is_defined dkenv cst' then
          if cst = cst' then raise Maybe else (true, ctx, Delta (cst, _tys))
        else (true, ctx, Delta (cst, _tys))
      else if is_defined dkenv cst' then (false, ctx, Delta (cst', _tys'))
      else raise Equal
  | Cst (cst, _tys), _ when is_defined dkenv cst ->
      (true, ctx, Delta (cst, _tys))
  | _, Cst (cst, _tys) when is_defined dkenv cst ->
      (false, ctx, Delta (cst, _tys))
  | Abs (var, _ty, _tel), Abs (var', _ty', _ter) ->
      let envl' = add_te_var envl var _ty in
      let envr' = add_te_var envr var' _ty' in
      _get_redex dkenv (envl', envr') (CAbs :: ctx) (_tel, _ter)
  | Forall (var, _ty, _tel), Forall (var', _ty', _ter) ->
      let envl' = add_te_var envl var _ty in
      let envr' = add_te_var envr var' _ty' in
      _get_redex dkenv (envl', envr') (CForall :: ctx) (_tel, _ter)
  | Impl (_tel, _ter), Impl (_tel', _ter') -> (
      try _get_redex dkenv (envl, envr) (CImplL :: ctx) (_tel, _tel')
      with Equal | Maybe ->
        _get_redex dkenv (envl, envr) (CImplR :: ctx) (_ter, _ter'))
  | App (Abs _, _), _ -> (true, ctx, Beta left)
  | _, App (Abs _, _) -> (false, ctx, Beta right)
  | App (_tel, _ter), App (_tel', _ter') -> (
      let leftdk = Decompile.decompile__term envl.dk left in
      let rightdk = Decompile.decompile__term envr.dk right in
      if Term.term_eq leftdk rightdk then raise Equal
      else if is_redexable dkenv _tel then get_app_redex dkenv true ctx left
      else if is_redexable dkenv _tel' then get_app_redex dkenv false ctx right
      else
        try _get_redex dkenv (envl, envr) (CAppL :: ctx) (_tel, _tel')
        with Equal ->
          _get_redex dkenv (envl, envr) (CAppR :: ctx) (_ter, _ter'))
  | App _, _ -> get_app_redex dkenv true ctx left
  | _, App _ -> get_app_redex dkenv false ctx right
  | _ -> assert false

let rec get_redex dkenv (envl, envr) ctx = function
  | Te left, Te right -> _get_redex dkenv (envl, envr) ctx (left, right)
  | ForallP (var, left), ForallP (var', right) ->
      let envl' = add_ty_var envl var in
      let envr' = add_ty_var envr var' in
      get_redex dkenv (envl', envr') (CForallP :: ctx) (left, right)
  | _ -> assert false

let get_redex dkenv env ctx lr =
  let is_left, ctx, redex = get_redex dkenv env ctx lr in
  (is_left, List.rev ctx, redex)

let _get_redex dkenv env ctx lr =
  let is_left, ctx, redex = _get_redex dkenv env ctx lr in
  (is_left, List.rev ctx, redex)

let rec _env_of_redex env ctx term =
  match (ctx, term) with
  | [], _ -> env
  | CAppR :: ctx, App (_, _ter) -> _env_of_redex env ctx _ter
  | CAppL :: ctx, App (_tel, _) -> _env_of_redex env ctx _tel
  | CImplR :: ctx, Impl (_, _ter) -> _env_of_redex env ctx _ter
  | CImplL :: ctx, Impl (_tel, _) -> _env_of_redex env ctx _tel
  | CForall :: ctx, Forall (var, _ty, _te) ->
      let env' = add_te_var env var _ty in
      _env_of_redex env' ctx _te
  | CAbs :: ctx, Abs (var, _ty, _te) ->
      let env' = add_te_var env var _ty in
      _env_of_redex env' ctx _te
  | _ -> assert false

let rec env_of_redex env ctx term =
  match (ctx, term) with
  | [], _ -> env
  | CForallP :: ctx, ForallP (var, term) ->
      let env' = add_ty_var env var in
      env_of_redex env' ctx term
  | _, Te _te -> _env_of_redex env ctx _te
  | _ -> assert false

let rec _apply ctx newterm term =
  match (ctx, term) with
  | [], _ -> newterm
  | CAppR :: ctx, App (_tel, _ter) -> App (_tel, _apply ctx newterm _ter)
  | CAppL :: ctx, App (_tel, _ter) -> App (_apply ctx newterm _tel, _ter)
  | CImplR :: ctx, Impl (_tel, _ter) -> Impl (_tel, _apply ctx newterm _ter)
  | CImplL :: ctx, Impl (_tel, _ter) -> Impl (_apply ctx newterm _tel, _ter)
  | CForall :: ctx, Forall (var, _ty, _te) ->
      Forall (var, _ty, _apply ctx newterm _te)
  | CAbs :: ctx, Abs (var, _ty, _te) -> Abs (var, _ty, _apply ctx newterm _te)
  | _ -> assert false

let rec apply ctx newterm term =
  match (ctx, term) with
  | CForallP :: ctx, ForallP (var, te) -> ForallP (var, apply ctx newterm te)
  | _, Te _te -> Te (_apply ctx newterm _te)
  | _ -> assert false

let newterm dkenv env _ redex =
  match redex with
  | Beta _te ->
      let _tedk = Decompile.decompile__term env.dk _te in
      Compile_type.compile__term dkenv env
        (Api.Env.unsafe_reduction dkenv
           ~red:Sttfatyping.ComputeStrategy.beta_one _tedk)
  | Delta (cst, _tys) ->
      let name = name_of cst in
      let _tedk = Decompile.decompile__term env.dk (Cst (cst, _tys)) in
      (* These two steps might be buggy in the future since we use
         SNF instead of WHNF because of the coercion eps *)
      let _tedk' =
        Api.Env.unsafe_reduction dkenv
          ~red:(Sttfatyping.ComputeStrategy.delta name)
          _tedk
      in
      let _tedk' =
        Api.Env.unsafe_reduction dkenv
          ~red:(Sttfatyping.ComputeStrategy.beta_steps (List.length _tys))
          _tedk'
      in
      Compile_type.compile__term dkenv env _tedk'

let _reduce dkenv env ctx redex _te =
  let* newterm = newterm dkenv env ctx redex in
  return @@ _apply ctx newterm _te

let reduce dkenv env ctx redex te =
  let* newterm = newterm dkenv env ctx redex in
  return @@ apply ctx newterm te

type 'a step = { is_left : bool; redex : redex; ctx : ctx list }

let get_step is_left redex ctx = { is_left; redex; ctx }

let _one_step dkenv env left right =
  let is_left, ctx, redex = _get_redex dkenv (env, env) [] (left, right) in
  if is_left then
    let env' = _env_of_redex env ctx left in
    let* left' = _reduce dkenv env' ctx redex left in
    let step = get_step is_left redex ctx in
    return (step, left', right)
  else
    let env' = _env_of_redex env ctx right in
    let* right' = _reduce dkenv env' ctx redex right in
    let step = get_step is_left redex ctx in
    return (step, left, right')

let one_step dkenv env left right =
  let is_left, ctx, redex = get_redex dkenv (env, env) [] (left, right) in
  if is_left then
    let env' = env_of_redex env ctx left in
    let* left' = reduce dkenv env' ctx redex left in
    let step = get_step is_left redex ctx in
    return (step, left', right)
  else
    let env' = env_of_redex env ctx right in
    let* right' = reduce dkenv env' ctx redex right in
    let step = get_step is_left redex ctx in
    return (step, left, right')

let empty_trace = { left = []; right = [] }

let rec _annotate_beta dkenv env _te : (_, [> Compile_type.error ]) result =
  if Sttfatyping._is_beta_normal dkenv env _te then return ([], _te)
  else
    let ctx, redex = _get_beta_redex env [] _te in
    let env' = _env_of_redex env ctx _te in
    let* _te' = _reduce dkenv env' ctx redex _te in
    let* trace, _tenf = _annotate_beta dkenv env _te' in
    return ((redex, ctx) :: trace, _tenf)

let rec annotate_beta dkenv env te =
  if Sttfatyping.is_beta_normal dkenv env te then return ([], te)
  else
    let ctx, redex = get_beta_redex env [] te in
    let env' = env_of_redex env ctx te in
    let* te' = reduce dkenv env' ctx redex te in
    let* trace, tenf = annotate_beta dkenv env te' in
    return ((redex, ctx) :: trace, tenf)

let annotate_beta dkenv env te =
  if !fast then return ([], te) else annotate_beta dkenv env te

let rec _annotate dkenv env left right =
  if Sttfatyping._eq env left right then return empty_trace
  else
    let* tracel, left' = _annotate_beta dkenv env left in
    let* tracer, right' = _annotate_beta dkenv env right in
    let trace_beta = { left = tracel; right = tracer } in
    if Sttfatyping._eq env left' right' then return trace_beta
    else
      let* step, left', right' = _one_step dkenv env left' right' in
      let* trace' = _annotate dkenv env left' right' in
      let trace'' =
        if step.is_left then
          { trace' with left = (step.redex, step.ctx) :: trace'.left }
        else { trace' with right = (step.redex, step.ctx) :: trace'.right }
      in
      return
        {
          left = trace_beta.left @ trace''.left;
          right = trace_beta.right @ trace''.right;
        }

let _annotate dkenv env left right =
  if !fast then return empty_trace else _annotate dkenv env left right

let rec annotate dkenv env left right =
  if Sttfatyping.eq env left right then return empty_trace
  else
    let* tracel, left' = annotate_beta dkenv env left in
    let* tracer, right' = annotate_beta dkenv env right in
    let trace_beta = { left = tracel; right = tracer } in
    if Sttfatyping.eq env left' right' then return trace_beta
    else
      let* step, left', right' = one_step dkenv env left' right' in
      let* trace' = annotate dkenv env left' right' in
      let trace'' =
        if step.is_left then
          { trace' with left = (step.redex, step.ctx) :: trace'.left }
        else { trace' with right = (step.redex, step.ctx) :: trace'.right }
      in
      return
        {
          left = trace_beta.left @ trace''.left;
          right = trace_beta.right @ trace''.right;
        }

let annotate dkenv env left right =
  if !fast then return empty_trace else annotate dkenv env left right
