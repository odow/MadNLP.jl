mutable struct MadNLPExecutionStats{T} <: AbstractExecutionStats
    status::Status
    solution::Vector{T}
    objective::T
    constraints::Vector{T}
    dual_feas::T
    primal_feas::T
    multipliers::Vector{T}
    multipliers_L::Vector{T}
    multipliers_U::Vector{T}
    iter::Int
    counters::NLPModels.Counters
    elapsed_time::Real
end

MadNLPExecutionStats(solver::MadNLPSolver) =MadNLPExecutionStats(
    solver.status,
    primal(solver.x),
    solver.obj_val,solver.c,
    solver.inf_du, solver.inf_pr,
    solver.y,
    primal(solver.zl),
    primal(solver.zu),
    solver.cnt.k, get_counters(solver.nlp),solver.cnt.total_time
)

function update!(stats::MadNLPExecutionStats, solver::MadNLPSolver)
    stats.status = solver.status
    stats.objective = solver.obj_val
    stats.dual_feas = solver.inf_du
    stats.primal_feas = solver.inf_pr
    stats.iter = solver.cnt.k
    stats.elapsed_time = solver.cnt.total_time
    return stats
end

get_counters(nlp::NLPModels.AbstractNLPModel) = nlp.counters
get_counters(nlp::NLPModels.AbstractNLSModel) = nlp.counters.counters
getStatus(result::MadNLPExecutionStats) = STATUS_OUTPUT_DICT[result.status]

# Exceptions
struct InvalidNumberException <: Exception
    callback::Symbol
end
struct NotEnoughDegreesOfFreedomException <: Exception end

# Utilities
has_constraints(solver) = solver.m != 0

function get_vars_info(solver)
    x_lb = get_lvar(solver.nlp)
    x_ub = get_uvar(solver.nlp)
    num_fixed = length(solver.ind_fixed)
    num_var = get_nvar(solver.nlp) - num_fixed
    num_llb_vars = length(solver.ind_llb)
    num_lu_vars = -num_fixed
    # Number of bounded variables
    for i in 1:get_nvar(solver.nlp)
        if (x_lb[i] > -Inf) && (x_ub[i] < Inf)
            num_lu_vars += 1
        end
    end
    num_uub_vars = length(solver.ind_uub)
    return (
        n_free=num_var,
        n_fixed=num_fixed,
        n_only_lb=num_llb_vars,
        n_only_ub=num_uub_vars,
        n_bounded=num_lu_vars,
    )
end

function get_cons_info(solver)
    g_lb = get_lcon(solver.nlp)
    g_ub = get_ucon(solver.nlp)
    # Classify constraints
    num_eq_cons, num_ineq_cons = 0, 0
    num_ue_cons, num_le_cons, num_lu_cons = 0, 0, 0
    for i in 1:get_ncon(solver.nlp)
        l, u = g_lb[i], g_ub[i]
        if l == u
            num_eq_cons += 1
        elseif l < u
            num_ineq_cons += 1
            if isinf(l) && isfinite(u)
                num_ue_cons += 1
            elseif isfinite(l) && isinf(u)
                num_le_cons +=1
            else isfinite(l) && isfinite(u)
                num_lu_cons += 1
            end
        end
    end
    return (
        n_eq=num_eq_cons,
        n_ineq=num_ineq_cons,
        n_only_lb=num_le_cons,
        n_only_ub=num_ue_cons,
        n_bounded=num_lu_cons,
    )
end

# Print functions -----------------------------------------------------------
function print_init(solver::AbstractMadNLPSolver)
    @notice(solver.logger,@sprintf("Number of nonzeros in constraint Jacobian............: %8i", get_nnzj(solver.nlp.meta)))
    @notice(solver.logger,@sprintf("Number of nonzeros in Lagrangian Hessian.............: %8i\n", get_nnzh(solver.nlp.meta)))
    var_info = get_vars_info(solver)
    con_info = get_cons_info(solver)

    if get_nvar(solver.nlp) < con_info.n_eq
        throw(NotEnoughDegreesOfFreedomException())
    end

    @notice(solver.logger,@sprintf("Total number of variables............................: %8i",var_info.n_free))
    @notice(solver.logger,@sprintf("                     variables with only lower bounds: %8i",var_info.n_only_lb))
    @notice(solver.logger,@sprintf("                variables with lower and upper bounds: %8i",var_info.n_bounded))
    @notice(solver.logger,@sprintf("                     variables with only upper bounds: %8i",var_info.n_only_ub))
    @notice(solver.logger,@sprintf("Total number of equality constraints.................: %8i",con_info.n_eq))
    @notice(solver.logger,@sprintf("Total number of inequality constraints...............: %8i",con_info.n_ineq))
    @notice(solver.logger,@sprintf("        inequality constraints with only lower bounds: %8i",con_info.n_only_lb))
    @notice(solver.logger,@sprintf("   inequality constraints with lower and upper bounds: %8i",con_info.n_bounded))
    @notice(solver.logger,@sprintf("        inequality constraints with only upper bounds: %8i\n",con_info.n_only_ub))
    return
end

function print_iter(solver::AbstractMadNLPSolver;is_resto=false)
    mod(solver.cnt.k,10)==0&& @info(solver.logger,@sprintf(
        "iter    objective    inf_pr   inf_du lg(mu)  ||d||  lg(rg) alpha_du alpha_pr  ls"))
    if is_resto
        RR = solver.RR::RobustRestorer
        inf_du = RR.inf_du_R
        inf_pr = RR.inf_pr_R
        mu = log10(RR.mu_R)
    else
        inf_du = solver.inf_du
        inf_pr = solver.inf_pr
        mu = log10(solver.mu)
    end
    @info(solver.logger,@sprintf(
        "%4i%s% 10.7e %6.2e %6.2e %5.1f %6.2e %s %6.2e %6.2e%s  %i",
        solver.cnt.k,is_resto ? "r" : " ",solver.obj_val/solver.obj_scale[],
        inf_pr, inf_du, mu,
        solver.cnt.k == 0 ? 0. : norm(primal(solver.d),Inf),
        solver.del_w == 0 ? "   - " : @sprintf("%5.1f",log(10,solver.del_w)),
        solver.alpha_z,solver.alpha,solver.ftype,solver.cnt.l))
    return
end

function print_summary_1(solver::AbstractMadNLPSolver)
    @notice(solver.logger,"")
    @notice(solver.logger,"Number of Iterations....: $(solver.cnt.k)\n")
    @notice(solver.logger,"                                   (scaled)                 (unscaled)")
    @notice(solver.logger,@sprintf("Objective...............:  % 1.16e   % 1.16e",solver.obj_val,solver.obj_val/solver.obj_scale[]))
    @notice(solver.logger,@sprintf("Dual infeasibility......:   %1.16e    %1.16e",solver.inf_du,solver.inf_du/solver.obj_scale[]))
    @notice(solver.logger,@sprintf("Constraint violation....:   %1.16e    %1.16e",norm(solver.c,Inf),solver.inf_pr))
    @notice(solver.logger,@sprintf("Complementarity.........:   %1.16e    %1.16e",
                                solver.inf_compl*solver.obj_scale[],solver.inf_compl))
    @notice(solver.logger,@sprintf("Overall NLP error.......:   %1.16e    %1.16e\n",
                                max(solver.inf_du*solver.obj_scale[],norm(solver.c,Inf),solver.inf_compl),
                                max(solver.inf_du,solver.inf_pr,solver.inf_compl)))
    return
end

function print_summary_2(solver::AbstractMadNLPSolver)
    solver.cnt.solver_time = solver.cnt.total_time-solver.cnt.linear_solver_time-solver.cnt.eval_function_time
    @notice(solver.logger,"Number of objective function evaluations             = $(solver.cnt.obj_cnt)")
    @notice(solver.logger,"Number of objective gradient evaluations             = $(solver.cnt.obj_grad_cnt)")
    @notice(solver.logger,"Number of constraint evaluations                     = $(solver.cnt.con_cnt)")
    @notice(solver.logger,"Number of constraint Jacobian evaluations            = $(solver.cnt.con_jac_cnt)")
    @notice(solver.logger,"Number of Lagrangian Hessian evaluations             = $(solver.cnt.lag_hess_cnt)")
    @notice(solver.logger,@sprintf("Total wall-clock secs in solver (w/o fun. eval./lin. alg.)  = %6.3f",
                                solver.cnt.solver_time))
    @notice(solver.logger,@sprintf("Total wall-clock secs in linear solver                      = %6.3f",
                                solver.cnt.linear_solver_time))
    @notice(solver.logger,@sprintf("Total wall-clock secs in NLP function evaluations           = %6.3f",
                                solver.cnt.eval_function_time))
    @notice(solver.logger,@sprintf("Total wall-clock secs                                       = %6.3f\n",
                                solver.cnt.total_time))
end


function string(solver::AbstractMadNLPSolver)
    """
                Interior point solver

                number of variables......................: $(get_nvar(solver.nlp))
                number of constraints....................: $(get_ncon(solver.nlp))
                number of nonzeros in lagrangian hessian.: $(get_nnzh(solver.nlp.meta))
                number of nonzeros in constraint jacobian: $(get_nnzj(solver.nlp.meta))
                status...................................: $(solver.status)
                """
end
print(io::IO,solver::AbstractMadNLPSolver) = print(io, string(solver))
show(io::IO,solver::AbstractMadNLPSolver) = print(io,solver)
