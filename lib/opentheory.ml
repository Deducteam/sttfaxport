open Extras
open Ast
open Openstt
open Environ
open Result.Monad

(* The memoization of Openstt is not efficient and can be highly increased. For that, the memoization of openstt should be turned off and the memoization should be done in this module. One may also want to handle alpha-renaming *)

module Conv = Sttfatyping.ComputeStrategy

let cur_md = ref ""
let sanitize id = id
let mk_id id = mk_name [] (sanitize id)
let mk_qid (md, id) = mk_name [ md ] id

let rec mk__ty = function
  | TyVar var -> mk_varType (mk_id @@ sov var)
  | Arrow (_tyl, _tyr) ->
      let _tys' = List.map mk__ty [ _tyl; _tyr ] in
      ty_of_tyOp (mk_tyOp (mk_id "->")) _tys'
  | TyOp (tyop, _tys) ->
      let _tys' = List.map mk__ty _tys in
      ty_of_tyOp (mk_tyOp (mk_qid tyop)) _tys'
  | Prop -> ty_of_tyOp (mk_tyOp (mk_id "bool")) []

let rec mk_ty = function ForallK (_, ty) -> mk_ty ty | Ty _ty -> mk__ty _ty

(* FIXME: buggy don't know why
   let memoization_ty = Hashtbl.create 101

   let mk__ty =
     let counter = ref (-1) in
     fun _ty ->
       if Hashtbl.mem memoization_ty _ty then
         mk_ref (Hashtbl.find memoization_ty _ty)
       else
         begin
           incr counter;
           Hashtbl.add memoization_ty _ty !counter;
           let ty' = mk__ty _ty in
           Format.eprintf "%a@." Web.print__ty _ty;
           mk_def ty' !counter
         end
*)
let rec mk__te dkenv ctx = function
  | TeVar var ->
      let _ty = List.assoc var ctx.te in
      let _ty' = mk__ty _ty in
      mk_var_term (mk_var (mk_id @@ sov var) _ty')
  | Abs (var, _ty, _te) ->
      let ctx' = add_te_var ctx var _ty in
      let _ty' = mk__ty _ty in
      let var' = mk_var (mk_id @@ sov var) _ty' in
      let _te' = mk__te dkenv ctx' _te in
      mk_abs_term var' _te'
  | App (_tel, _ter) ->
      let _tel' = mk__te dkenv ctx _tel in
      let _ter' = mk__te dkenv ctx _ter in
      mk_app_term _tel' _ter'
  | Forall (var, _ty, _te) ->
      let _ty' = mk__ty _ty in
      let f' = mk__te dkenv ctx (Abs (var, _ty, _te)) in
      mk_forall_term f' _ty'
  | Impl (_tel, _ter) ->
      let _tel' = mk__te dkenv ctx _tel in
      let _ter' = mk__te dkenv ctx _ter in
      mk_impl_term _tel' _ter'
  | AbsTy (var, _te) ->
      let ctx' = add_ty_var ctx var in
      mk__te dkenv ctx' _te
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
      term_of_const (const_of_name (mk_qid cst)) (mk__ty _ty')

let rec mk_te dkenv ctx = function
  | ForallP (var, te) ->
      let ctx' = add_ty_var ctx var in
      mk_te dkenv ctx' te
  | Te _te -> mk__te dkenv ctx _te

(* FIXME: buggy don't know why
   let memoization_te = Hashtbl.create 101

   let mk__te =
     let counter = ref (-1) in
     fun ctx _te ->
       if Hashtbl.mem memoization_te _te then
         mk_ref (Hashtbl.find memoization_te _te)
       else
         begin
           incr counter;
           Hashtbl.add memoization_te _te !counter;
           let te' = mk__te ctx _te in
           Format.eprintf "%a@." Web.print__te _te;
           mk_def te' !counter
         end
*)
let thm_of_const dkenv cst =
  try return (thm_of_const_name (mk_qid cst))
  with Failure _ ->
    let name = Environ.name_of cst in
    let term = Term.mk_Const Basic.dloc name in
    let te = Api.Env.unsafe_reduction dkenv ~red:(Conv.delta name) term in
    let* te' = Compile_type.compile_term dkenv Environ.empty_env te in
    let te' = mk_te dkenv empty_env te' in
    let ty = Api.Env.infer dkenv term in
    let ty' = Compile_type.compile_wrapped_type dkenv Environ.empty_env ty in
    let ty' = mk_ty ty' in
    let const = const_of_name (mk_qid cst) in
    let constterm = term_of_const const ty' in
    let eq = mk_equal_term constterm te' ty' in
    return (mk_axiom (mk_hyp []) eq)

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

let mk_rewrite dkenv ctx r =
  let open Basic in
  match r with
  | Beta t ->
      let t' = mk__te dkenv ctx t in
      return @@ mk_betaConv t'
  | Delta ((md, id), _tys) ->
      let cst = mk_name (mk_mident md) (mk_ident id) in
      let ty = Api.Env.get_type dkenv dloc cst in
      let ty' = Compile_type.compile_type dkenv ctx ty in
      let vars = get_vars ty' in
      assert (List.length vars = List.length _tys);
      let vars' = List.map (fun x -> mk_id (sov x)) vars in
      let _tys' = List.map mk__ty _tys in
      let* thm = thm_of_const dkenv (md, id) in
      return @@ mk_subst thm (List.combine vars' _tys') []

let mk_beta dkenv env _te =
  let _te' = mk__te dkenv env _te in
  mk_betaConv _te'

let mk_delta dkenv ctx cst _tys =
  let open Basic in
  let* thm = thm_of_const dkenv cst in
  let term =
    Term.mk_Const dloc (mk_name (mk_mident (fst cst)) (mk_ident (snd cst)))
  in
  let ty = Api.Env.infer dkenv ~ctx:[] term in
  let ty' = Compile_type.compile_wrapped_type dkenv ctx ty in
  let vars = get_vars ty' in
  let vars' = List.map (fun x -> mk_id (sov x)) vars in
  let _tys' = List.map mk__ty _tys in
  assert (List.length vars = List.length _tys);
  let subst = List.combine vars' _tys' in
  return @@ mk_subst thm subst []

let rec mk__ctx dkenv env thm ctx left right =
  match (ctx, left, right) with
  | [], _, _ -> thm
  | CAbsTy :: ctx, AbsTy (_, _te), AbsTy (_, _te') ->
      mk__ctx dkenv env thm ctx _te _te'
  | CAbs :: ctx, Abs (var, _ty, _te), Abs (var', _ty', _te') ->
      assert (var = var');
      assert (_ty = _ty');
      let env' = add_te_var env var _ty in
      let var = mk_var (mk_id @@ sov var) (mk__ty _ty) in
      let thm = mk__ctx dkenv env' thm ctx _te _te' in
      mk_absThm var thm
  | CForall :: ctx, Forall (var, _ty, _tel), Forall (var', _ty', _ter) ->
      assert (var = var');
      assert (_ty = _ty');
      let env' = add_te_var env var _ty in
      let _tel' = mk__te dkenv env' _tel in
      let _ter' = mk__te dkenv env' _ter in
      let thm = mk__ctx dkenv env' thm ctx _tel _ter in
      mk_forall_equal thm (mk_id @@ sov var) _tel' _ter' (mk__ty _ty)
  | CAppL :: ctx, App (_tel, _ter), App (_tel', _ter') ->
      let thm = mk__ctx dkenv env thm ctx _tel _tel' in
      mk_appThm thm (mk_refl (mk__te dkenv env _ter))
  | CAppR :: ctx, App (_tel, _ter), App (_tel', _ter') ->
      let thm = mk__ctx dkenv env thm ctx _ter _ter' in
      mk_appThm (mk_refl (mk__te dkenv env _tel)) thm
  | CImplL :: ctx, Impl (_tel1, _ter1), Impl (_tel2, _ter2) ->
      let _tel1' = mk__te dkenv env _tel1 in
      let _ter1' = mk__te dkenv env _ter1 in
      let _tel2' = mk__te dkenv env _tel2 in
      let _ter2' = mk__te dkenv env _ter2 in
      let thm = mk__ctx dkenv env thm ctx _tel1 _tel2 in
      mk_impl_equal thm (mk_refl _ter1') _tel1' _ter1' _tel2' _ter2'
  | CImplR :: ctx, Impl (_tel1, _ter1), Impl (_tel2, _ter2) ->
      let _tel1' = mk__te dkenv env _tel1 in
      let _ter1' = mk__te dkenv env _ter1 in
      let _tel2' = mk__te dkenv env _tel2 in
      let _ter2' = mk__te dkenv env _ter2 in
      let thm = mk__ctx dkenv env thm ctx _ter1 _ter2 in
      mk_impl_equal (mk_refl _tel1') thm _tel1' _ter1' _tel2' _ter2'
  | _ -> assert false

let rec mk_ctx dkenv env thm ctx left right =
  match (ctx, left, right) with
  | CForallP :: ctx, ForallP (var, _te), ForallP (_, _te') ->
      let env' = add_ty_var env var in
      let thm = mk_ctx dkenv env' thm ctx _te _te' in
      thm
  | _, Te _te, Te _te' -> mk__ctx dkenv env thm ctx _te _te'
  | _, _, _ -> assert false

let mk_rewrite_step dkenv env term (redex, ctx) =
  let env' = Tracer.env_of_redex env ctx term in
  let* term' = Tracer.reduce dkenv env' ctx redex term in
  let* thm =
    match redex with
    | Delta (name, _tys) -> mk_delta dkenv env' name _tys
    | Beta _te -> return @@ mk_beta dkenv env' _te
  in
  let thm = mk_ctx dkenv env thm ctx term term' in
  return (term', thm)

let mk_rewrite_seq dkenv env term rws =
  match rws with
  | [] -> return (term, mk_refl (mk_te dkenv env term))
  | [ rw ] -> mk_rewrite_step dkenv env term rw
  | rw :: rws ->
      let* term', rw = mk_rewrite_step dkenv env term rw in
      let f term_thm rw =
        let* term, thm = term_thm in
        let* term', thm' = mk_rewrite_step dkenv env term rw in
        return (term', mk_trans thm thm')
      in
      List.fold_left f (return (term', rw)) rws

let mk_trace dkenv env left right trace =
  let* _, thml = mk_rewrite_seq dkenv env left trace.left in
  let* _, thmr = mk_rewrite_seq dkenv env right trace.right in
  let thmr' = mk_sym thmr in
  return @@ mk_trans thml thmr'

let rec mk_proof dkenv env =
  let open Basic in
  function
  | Assume (j, _) -> return @@ mk_assume (mk_te dkenv env j.thm)
  | Lemma (cst, _) -> (
      try return @@ thm_of_lemma (mk_qid cst)
      with _ ->
        let te = Api.Env.get_type dkenv dloc (name_of cst) in
        let* te = Compile_type.compile_wrapped_term dkenv empty_env te in
        return @@ mk_axiom (mk_hyp []) (mk_te dkenv empty_env te))
  | ForallE (_, proof, u) -> (
      match (judgment_of proof).thm with
      | Te (Forall (var, _ty, _te)) ->
          let f' = mk__te dkenv env (Abs (var, _ty, _te)) in
          let u' = mk__te dkenv env u in
          let _ty' = mk__ty _ty in
          let* proof' = mk_proof dkenv env proof in
          return @@ mk_rule_elim_forall proof' f' _ty' u'
      | _ -> assert false)
  | ForallI (_, proof, var) ->
      let j' = judgment_of proof in
      let _, _ty =
        List.find (fun (x, _ty) -> if x = var then true else false) j'.te
      in
      let env' = add_te_var env var _ty in
      let* proof' = mk_proof dkenv env' proof in
      let _ty' = mk__ty _ty in
      let thm' = mk_te dkenv env' j'.thm in
      return @@ mk_rule_intro_forall (mk_id @@ sov var) _ty' thm' proof'
  | ImplE (j, prfpq, prfp) ->
      let p = (judgment_of prfp).thm in
      let q = j.thm in
      let p' = mk_te dkenv env p in
      let q' = mk_te dkenv env q in
      let* prfp' = mk_proof dkenv env prfp in
      let* prfpq' = mk_proof dkenv env prfpq in
      return @@ mk_rule_elim_impl prfp' prfpq' p' q'
  | ImplI (_, proof, var) ->
      let j' = judgment_of proof in
      let _, p =
        TeSet.choose (TeSet.filter (fun (x, _ty) -> x = sov var) j'.hyp)
      in
      let q = j'.thm in
      let env' =
        add_prf_ctx env (sov var) (Decompile.decompile__term env.dk p) p
      in
      let p' = mk__te dkenv env p in
      let q' = mk_te dkenv env q in
      let* proof' = mk_proof dkenv env' proof in
      return @@ mk_rule_intro_impl proof' p' q'
  | ForallPE (_, proof, _ty) -> (
      match (judgment_of proof).thm with
      | ForallP (var, _) ->
          let subst = [ (mk_id @@ sov var, mk__ty _ty) ] in
          let* proof' = mk_proof dkenv env proof in
          return @@ mk_subst proof' subst []
      | _ -> assert false)
  | ForallPI (_, proof, var) ->
      let env' = add_ty_var env var in
      mk_proof dkenv env' proof
  | Conv (j, proof, trace) ->
      let right = j.thm in
      let left = (judgment_of proof).thm in
      let* proof = mk_proof dkenv env proof in
      let* trace = mk_trace dkenv env left right trace in
      return @@ mk_eqMp proof trace

let content = ref ""
let string_of_item _ _ = "Printing for OpenTheory is not supported right now."
(*
  let print_item fmt = function
    | Parameter(name,ty) ->
      let ty' = mk_ty ty in
      let name' = mk_qid name in
      let lhs = term_of_const (const_of_name name') ty' in
      let eq = mk_equal_term lhs lhs ty' in
      mk_thm name' eq (mk_hyp []) (mk_refl lhs)
    | Definition(cst,ty,te) ->
      let cst' = mk_qid cst in
      let te' = mk_te Environ.empty_env te in
      let ty' = mk_ty ty in
      let eq = mk_equal_term (term_of_const (const_of_name cst') ty') te' ty' in
      let thm = thm_of_const cst in
      mk_thm cst' eq (mk_hyp []) thm
  | Theorem(cst,te,_)
  | Axiom(cst,te) ->
    let te' = mk_te empty_env te in
    let hyp = mk_hyp [] in
    mk_thm (mk_qid cst)  te' hyp (mk_axiom hyp te')
  | TyOpDef(tyop,arity) ->
    let tyop' = mk_qid tyop in
    let tyop' = mk_tyOp tyop' in
    let ty' = ty_of_tyOp tyop' [] in
    let name' = mk_qid ("","foo") in
    let lhs = term_of_const (const_of_name  name') ty' in
    let eq = mk_equal_term lhs lhs ty' in
    mk_thm name' eq (mk_hyp []) (mk_refl lhs)
  in
  (* let fmt = Format.formatter_of_out_channel @@ open_out "/tmp/test.art" in *)
  let str_fmt = Format.str_formatter in
  set_oc str_fmt;
  let length = Buffer.length Format.stdbuf in
  version ();
  print_item str_fmt item;
  clean ();
  let length' = Buffer.length Format.stdbuf in
  content := Buffer.sub Format.stdbuf length (length'-length);
  Buffer.truncate Format.stdbuf length;
  !content
*)

let print_item dkenv _ = function
  | Parameter _ -> ()
  | Definition (cst, ty, te) ->
      (*    let te' = mk_te empty_env te in *)
      let cst' = mk_qid cst in
      let te' = mk_te dkenv Environ.empty_env te in
      let ty' = mk_ty ty in
      let eq = mk_equal_term (term_of_const (const_of_name cst') ty') te' ty' in
      let thm = Result.get_ok @@ thm_of_const dkenv cst in
      mk_thm cst' eq (mk_hyp []) thm
  | Axiom (cst, te) ->
      let te' = mk_te dkenv empty_env te in
      let hyp = mk_hyp [] in
      mk_thm (mk_qid cst) te' hyp (mk_axiom hyp te')
  | Theorem (cst, te, proof) ->
      let te' = mk_te dkenv empty_env te in
      let hyp' = mk_hyp [] in
      let proof' = Result.get_ok @@ mk_proof dkenv empty_env proof in
      mk_thm (mk_qid cst) te' hyp' proof'
  | TypeDecl _ -> ()
  | TypeDef _ -> failwith "[OpenTheory] Type definitions not handled right now"

let print_ast oc env ast =
  Buffer.clear Format.stdbuf;
  reset ();
  let oc_tmp = Format.str_formatter in
  set_oc oc_tmp;
  version ();
  List.iter (fun item -> print_item env oc_tmp item) ast.items;
  clean ();
  content := Buffer.contents Format.stdbuf;
  Printf.fprintf oc "%s" !content
