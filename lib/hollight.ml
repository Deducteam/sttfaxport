open Extras
open Ast
open Holstt.HolSTT
open Environ
open Result.Monad

(* The memoization of Openstt is not efficient and can be highly increased. For
   that, the memoization of openstt should be turned off and the memoization
   should be done in this module. One may also want to handle alpha-renaming *)

module Conv = Sttfatyping.ComputeStrategy

let cur_md = ref ""

let forbidden_id =
  ref
    [
      "_0";
      "mod";
      "bool";
      "and";
      "not";
      "true";
      "false";
      "or";
      "o";
      "div";
      "divides";
      "prime";
      "gcd";
      "exp";
    ]

let sanitize b id =
  let u_id = String.uncapitalize_ascii id in
  if List.mem id !forbidden_id || List.mem u_id !forbidden_id then
    (*let () = Printf.printf "OOPS, issue with %s or %s, replacing by %s.\n" id u_id ("mat_"^id) in*)
    "mat_" ^ id
  else if b then u_id
  else id

let mk_id b id = mk_name [] (sanitize b id)

let rec mk__ty = function
  | TyVar var -> mk_varType (mk_id false @@ sov var)
  | Arrow (_tyl, _tyr) ->
      let _tys' = List.map mk__ty [ _tyl; _tyr ] in
      ty_of_tyOp (mk_tyOp (mk_id false "->")) _tys'
  | TyOp (tyop, _tys) ->
      let _tys' = List.map mk__ty _tys in
      ty_of_tyOp (mk_tyOp ("mat_" ^ snd tyop)) _tys'
  | Prop -> ty_of_tyOp (mk_tyOp "bool") []

let rec mk_ty = function ForallK (_, ty) -> mk_ty ty | Ty _ty -> mk__ty _ty

let rec mk__te dkenv ctx conflicts ?(avoid = StrSet.empty) ?(total = false) =
  function
  | TeVar var ->
      if List.mem_assoc var conflicts then
        let new_var = List.assoc var conflicts in
        let _ty = List.assoc new_var ctx.te in
        let _ty' = mk__ty _ty in
        mk_var_term (mk_var (mk_id false @@ sov new_var) _ty')
      else
        let _ty = List.assoc var ctx.te in
        let _ty' = mk__ty _ty in
        mk_var_term (mk_var (mk_id false @@ sov var) _ty')
  | Abs (var, _ty, _te) ->
      if List.mem_assoc var ctx.te || StrSet.mem (mk_id false @@ sov var) avoid
      then
        let new_var =
          gen_fresh ctx ~avoid (mk_ident (mk_id false @@ sov var))
        in
        let ctx' = add_te_var ctx (term_var new_var) _ty in
        let _ty' = mk__ty _ty in
        let new_var' = mk_var (mk_id false (string_of_ident new_var)) _ty' in
        let _te' =
          mk__te dkenv ctx' ((var, term_var new_var) :: conflicts) ~avoid _te
        in
        mk_abs_term new_var' _te'
      else
        let ctx' = add_te_var ctx var _ty in
        let _ty' = mk__ty _ty in
        let var' = mk_var (mk_id false @@ sov var) _ty' in
        let _te' = mk__te dkenv ctx' conflicts ~avoid ~total _te in
        mk_abs_term var' _te'
  | App (_tel, _ter) ->
      let _tel' = mk__te dkenv ctx conflicts ~avoid ~total _tel in
      let _ter' = mk__te dkenv ctx conflicts ~avoid ~total _ter in
      mk_app_term _tel' _ter'
  | Forall (var, _ty, _te) ->
      let _ty' = mk__ty _ty in
      let f' = mk__te dkenv ctx conflicts ~avoid (Abs (var, _ty, _te)) in
      mk_forall_term f' _ty'
  | Impl (_tel, _ter) ->
      let _tel' = mk__te dkenv ctx conflicts ~avoid ~total _tel in
      let _ter' = mk__te dkenv ctx conflicts ~avoid ~total _ter in
      mk_impl_term _tel' _ter'
  | AbsTy (var, _te) ->
      let ctx' = add_ty_var ctx var in
      mk__te dkenv ctx' conflicts ~avoid ~total _te
  | Cst (cst, _tys) ->
      let open Basic in
      let name = name_of cst in
      let _tys' = List.map (Decompile.decompile__type ctx.dk) _tys in
      let cst' =
        match _tys' with
        | [] -> Term.mk_Const dloc name
        | x :: t -> Term.mk_App (Term.mk_Const dloc name) x t
      in
      let _ty = Api.Env.infer dkenv ~ctx:ctx.dk cst' in
      let _ty' =
        Compile_type.compile_wrapped__type dkenv ctx
          (Api.Env.unsafe_reduction dkenv ~red:Conv.beta_only _ty)
      in
      let cst'' = sanitize true (snd cst) in
      if total || not (frees_ty _ty' = VarSet.empty) then
        mk_var_term (mk_var (sanitize true (snd cst)) (mk__ty _ty'))
      else term_of_const (const_of_name cst'') (mk__ty _ty')

let rec mk_te dkenv ctx ?(avoid = StrSet.empty) ?(total = false) = function
  | ForallP (var, te) ->
      let ctx' = add_ty_var ctx var in
      mk_te dkenv ctx' ~avoid ~total te
  | Te _te -> mk__te dkenv ctx [] ~avoid ~total _te

let rec app__te f ctx = function
  | ForallP (var, te) ->
      let ctx' = add_ty_var ctx var in
      app__te f ctx' te
  | Te _te -> f ctx _te

let rec _ty_of_ty = function ForallK (_, t) -> _ty_of_ty t | Ty t -> t

let thm_of_const dkenv cst =
  let cst_name = sanitize true (snd cst) in
  try thm_of_const_name cst_name
  with Failure _ ->
    let name = Environ.name_of cst in
    let term = Term.mk_Const Basic.dloc name in
    let te = Api.Env.unsafe_reduction dkenv ~red:(Conv.delta name) term in
    let* te' = Compile_type.compile_term dkenv Environ.empty_env te in
    let te' = mk_te dkenv empty_env te' in
    let ty = Api.Env.infer dkenv term in
    let ty' = Compile_type.compile_wrapped_type dkenv Environ.empty_env ty in
    let ty' = mk_ty ty' in
    let const = const_of_name cst_name in
    let constterm = term_of_const const ty' in
    let eq = mk_equal_term constterm te' ty' in
    return (mk_def cst_name cst_name eq ty')

let add_prf_ctx env id _te _te' =
  {
    env with
    k = env.k + 1;
    prf = (id, _te') :: env.prf;
    dk = (Basic.dloc, Basic.mk_ident id, _te) :: env.dk;
  }

let rec get_vars = function
  | Ty _ -> []
  | ForallK (var, ty) -> var :: get_vars ty

let mk_conv comment right proof = conv_proof comment right proof

let rec depth_convs n1 n2 = function
  | Conv (_, pi, trace) ->
      let new_n1 = n1 + List.length trace.left in
      let new_n2 = n2 + List.length trace.right in
      depth_convs new_n1 new_n2 pi
  | pi -> (n1, n2, pi)

let is_var = function TeVar _ -> true | _ -> false

let rec is_in_var_ty ty = function
  | Tyvar tyv -> compare ty tyv = 0
  | Tyapp (_, tylist) -> List.exists (is_in_var_ty ty) tylist

let rec is_in_var ty = function
  | Var (_, ty') -> is_in_var_ty ty ty'
  | Comb (t1, t2) -> is_in_var ty t1 || is_in_var ty t2
  | Abs (var, t) -> is_in_var ty var || is_in_var ty t
  | _ -> false

let issue_tyvar u _ty =
  VarSet.exists (fun tyvar -> not (is_in_var (sov tyvar) u)) (frees_ty _ty)

let rec mk_proof dkenv env = function
  | Assume (j, _) -> (mk_assume (mk_te dkenv env j.thm), VarSet.empty)
  | Lemma (cst, _) ->
      let thm_name = sanitize true (snd cst) in
      (Thm thm_name, VarSet.empty)
  | ForallE (_, proof, u) -> (
      match (judgment_of proof).thm with
      | Te (Forall (_, _ty, _te)) ->
          let frees_u = frees u in
          let u' = mk__te dkenv env [] u in
          let u'' =
            if issue_tyvar u' _ty then mk__te dkenv env [] ~total:true u else u'
          in
          let _ty' = mk__ty _ty in
          let proof', pc = mk_proof dkenv env proof in
          (mk_rule_elim_forall "" u'' proof', VarSet.union frees_u pc)
      | _ -> assert false)
  | ForallI (_, proof, var) ->
      let j' = judgment_of proof in
      let _, _ty = List.find (fun (x, _ty) -> x = var) j'.te in
      let env' = add_te_var env var _ty in
      let proof', pc = mk_proof dkenv env' proof in
      let _ty' = mk__ty _ty in
      (mk_rule_intro_forall (mk_id false @@ sov var) _ty' proof', pc)
  | ImplE (_, prfpq, prfp) ->
      let prfp', pcp = mk_proof dkenv env prfp in
      let prfpq', pcpq = mk_proof dkenv env prfpq in
      (mk_rule_elim_impl prfpq' prfp', VarSet.union pcp pcpq)
  | ImplI (_, proof, var) ->
      let j' = judgment_of proof in
      let _, p =
        TeSet.choose (TeSet.filter (fun (x, _ty) -> x = sov var) j'.hyp)
      in
      let env' =
        add_prf_ctx env (sov var) (Decompile.decompile__term env.dk p) p
      in
      let p' = mk__te dkenv env [] p in
      let proof', pc = mk_proof dkenv env' proof in
      (mk_rule_intro_impl p' proof', pc)
  | ForallPE (_, proof, _ty) -> (
      match (judgment_of proof).thm with
      | ForallP (var, _) ->
          let subst =
            [ (mk__ty (TyVar var) (* (TyVar (mk_id false var)) *), mk__ty _ty) ]
          in
          let proof', pc = mk_proof dkenv env proof in
          (mk_subst subst [] proof', pc)
      | _ -> assert false)
  | ForallPI (_, proof, var) ->
      let env' = add_ty_var env var in
      mk_proof dkenv env' proof
  | Conv (j, proof, trace) ->
      let right = j.thm in
      let n1 = List.length trace.left in
      let n2 = List.length trace.right in
      let n1', n2', proof' = depth_convs n1 n2 proof in
      let proof'', pc = mk_proof dkenv env proof' in
      if n1' = 0 && n2' = 0 then (proof'', pc)
      else
        (* REVIEW maybe we can keep the avoid set as a set of variables? *)
        let avoid = VarSet.fold (fun v -> StrSet.add (sov v)) pc StrSet.empty in
        let _ty = app__te (Sttfatyping._infer dkenv) env right in
        let right' = mk_te dkenv env ~avoid right in
        let right'' =
          if issue_tyvar right' _ty then
            mk_te dkenv env ~avoid ~total:true right
          else right'
        in
        (mk_conv "" right'' proof'', pc)

let print_item dkenv ?(short = false) = function
  | Parameter (cst, ty) -> (
      try
        let ty' = mk_ty ty in
        let cst' = sanitize true (snd cst) in
        if short then print_var !oc (Var (cst', ty')) else mk_parameter cst' ty'
      with _ -> assert false)
  | Definition (cst, ty, te) -> (
      try
        let cst' = sanitize true (snd cst) in
        let te' = mk_te dkenv Environ.empty_env te in
        let ty' = mk_ty ty in
        let eq =
          mk_equal_term (term_of_const (const_of_name cst') ty') te' ty'
        in
        match thm_of_const dkenv cst with
        | Ok (Sequent (_, _, _, pi)) ->
            if short then print_term false !oc eq
            else mk_thm cst' eq (mk_hyp []) pi
        | Error _ ->
            (* TODO error printing *)
            Format.eprintf "[HOLLIGHT]";
            exit 1
      with _ -> assert false)
  | Axiom (cst, te) ->
      let te' = mk_te dkenv empty_env te in
      let hyp = mk_hyp [] in
      let (Sequent (_, _, _, pi)) =
        mk_axiom (sanitize true (snd cst)) hyp te'
      in
      (* Axioms just have conclusions in STT and HOL Light *)
      (* Else, introductions of implication would have to be added *)
      if short then Format.fprintf !oc "|- %a" (print_term false) te'
      else mk_thm (sanitize true (snd cst)) te' hyp pi
  | Theorem (cst, te, proof) -> (
      try
        let te' = mk_te dkenv empty_env te in
        let hyp' = mk_hyp [] in
        let cst' = sanitize true (snd cst) in
        if short then
          print_thm_debug !oc (Sequent (cst', hyp', te', dummy_proof))
        else
          let proof', _ = mk_proof dkenv empty_env proof in
          mk_thm cst' te' hyp' proof'
      with _ -> assert false)
  | TypeDecl (name, arity) -> (
      try
        if short then Format.fprintf !oc "%s" ("mat" ^ snd name)
        else mk_type ("mat_" ^ snd name) arity
      with _ -> assert false)
  | TypeDef _ -> failwith "[HOL Light] Type definitions not handled right now"

let content = ref ""

let string_of_item dkenv item =
  let str_fmt = Format.str_formatter in
  set_oc str_fmt;
  print_item dkenv ~short:true item;
  Format.flush_str_formatter ()

let print_ast oc env ast =
  Buffer.clear Format.stdbuf;
  let oc_tmp = Format.str_formatter in
  set_oc oc_tmp;
  List.iter (print_item env) ast.items;
  content := Buffer.contents Format.stdbuf;
  Printf.fprintf oc "%s" !content
