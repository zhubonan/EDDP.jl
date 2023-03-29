using LinearAlgebra
using CellBase
using EDDP
using EDDP: get_energy, get_cell
using NLSolversBase
using Test
using Flux

function alter_pos(f, cell, pos, args...)
    pb = get_positions(cell)
    set_positions!(cell, reshape(pos, size(get_positions(cell))...))
    #cell.positions[:] .= vec(pos)
    out = f((cell, pos, args...))
    set_positions!(cell, pb)
    return out
end

function alter_pos_vc(f, vc, pos, args...)
    pb = get_positions(vc)
    set_positions!(vc, reshape(pos, size(pb)...))
    out = f((vc, pos, args...))
    set_positions!(vc, pb)
    return out
end

function alter_strain(f, cell, s, args...)
    cb = get_cellmat(cell)
    pb = get_positions(cell)
    smat = diagm([1.0, 1.0, 1.0])
    smat[:] .+= s
    set_cellmat!(cell, smat * cb; scale_positions=true)
    out = f((cell, s, args...))
    set_cellmat!(cell, cb; scale_positions=true)
    set_positions!(cell, pb)
    out
end


function _fd_features_strain(calc, s)
    alter_strain(calc, s) do x
        EDDP.update_feature_vector!(calc; rebuild_nl=true, gradients=true)
        copy(calc.force_buffer.fvec)
    end
end

function _fd_features(calc, s)
    alter_pos(calc, s) do _
        EDDP.update_feature_vector!(calc; rebuild_nl=true, gradients=true)
        copy(calc.force_buffer.fvec)
    end
end

function _fd_energy(calc, p)
    alter_pos(calc, p) do _
        calc.param.energy_calculated = false
        get_energy(calc)
    end
end

function _fd_energy_vc(calc, p)
    alter_pos_vc(calc, p) do _
        calc.calc.param.energy_calculated = false
        eng = get_energy(calc)
        eng
    end
end

function _fd_strain(calc, p)
    alter_strain(get_cell(calc), p) do _
        get_energy(calc)
    end
end


include("utils.jl")

@testset "Force buffer" begin

    cell = _h2_cell()
    cf = _generate_cf(cell)
    n1bd = EDDP.feature_size(cf)[1]
    fvec = vcat(
        EDDP.one_body_vectors(cell, cf),
        EDDP.feature_vector2(cf.two_body, cell),
        EDDP.feature_vector3(cf.three_body, cell),
    )
    fb = EDDP.ForceBuffer(fvec; ndims=3, core=nothing)

    EDDP.compute_fv_gv!(fb, cf.two_body, cf.three_body, cell; offset=n1bd)
    @test allclose(fb.fcore, zeros(size(fb.fcore)))
    @test allclose(fb.score, zeros(3, 3))
    @test fb.ecore[1] == 0

    # With increased core size
    fb = EDDP.ForceBuffer(fvec; ndims=3, core=EDDP.CoreReplusion(3.0))
    EDDP.compute_fv_gv!(fb, cf.two_body, cf.three_body, cell; offset=n1bd)

    @test !allclose(fb.fcore, zeros(size(fb.fcore)))
    @test fb.ecore[1] != 0.0
    @test fb.score[1] != zeros(3, 3)



    function fv(cell, pos, cf)
        alter_pos(cell, pos, cf) do (cell, pos, cf)
            vcat(
                EDDP.feature_vector2(cf.two_body, cell),
                EDDP.feature_vector3(cf.three_body, cell),
            )
        end
    end

    function sv(cell, s, cf)
        alter_strain(cell, s, cf) do (cell, s, cf)
            vcat(
                EDDP.feature_vector2(cf.two_body, cell),
                EDDP.feature_vector3(cf.three_body, cell),
            )
        end
    end

    # Gradients
    gvec = fb.gvec
    stotv = fb.stotv

    p0 = cell.positions
    od = NLSolversBase.OnceDifferentiable(
        x -> fv(cell, x, cf),
        p0,
        fv(cell, p0, cf);
        inplace=false,
    )
    jac = reshape(NLSolversBase.jacobian!(od, p0), 6, 2, 3, 2)
    gtmp = fb.gvec[:, 1+n1bd:end, :, :]
    gtmp = permutedims(gtmp, [2, 3, 1, 4])
    @test allclose(vec(jac), vec(gtmp), atol=1e-3)

    s0 = zeros(9)
    od = NLSolversBase.OnceDifferentiable(
        x -> sv(cell, x, cf),
        s0,
        sv(cell, s0, cf);
        inplace=false,
    )
    jac = NLSolversBase.jacobian!(od, s0)
    @test allclose(
        vec(jac),
        vec(permutedims(stotv[:, :, 1+n1bd:end, :], [3, 4, 1, 2])),
        atol=1e-3,
    )


    # Cores
    function core_forces(cell, pos, cf, n1bd)
        alter_pos(cell, pos, cf) do (cell, pos, cf)
            EDDP.compute_fv_gv!(fb, cf.two_body, cf.three_body, cell; offset=n1bd)
            fb.ecore[1]
        end
    end

    function core_stress(cell, pos, cf, n1bd)
        alter_strain(cell, pos, cf) do (cell, pos, cf)
            EDDP.compute_fv_gv!(fb, cf.two_body, cf.three_body, cell; offset=n1bd)
            fb.ecore[1]
        end
    end

    EDDP.compute_fv_gv!(fb, cf.two_body, cf.three_body, cell; offset=n1bd)
    fcore = copy(fb.fcore)
    score = copy(fb.score)

    p0 = cell.positions
    od = NLSolversBase.OnceDifferentiable(
        x -> core_forces(cell, x, cf, n1bd),
        p0,
        core_forces(cell, p0, cf, n1bd);
        inplace=false,
    )
    grad = reshape(NLSolversBase.gradient!(od, p0), 3, length(cell))
    @test allclose(-fcore, grad; atol=1e-4)

    s0 = zeros(9)
    od = NLSolversBase.OnceDifferentiable(
        x -> core_stress(cell, x, cf, n1bd),
        s0,
        core_stress(cell, s0, cf, n1bd);
        inplace=false,
    )
    grad = reshape(NLSolversBase.gradient!(od, s0), 3, 3)
    @test allclose(grad, -score, atol=1e-3)
end

@testset "Gradients" begin

    calc = _get_calc()
    EDDP.calculate!(calc; forces=true)
    n1bd = EDDP.feature_size(calc.cf)[1]
    gtot = copy(calc.force_buffer.gvec)

    cell = EDDP.get_cell(calc)
    p0 = cell.positions[:]


    # Numerical differentiations
    od = NLSolversBase.OnceDifferentiable(
        x -> _fd_features(calc, x),
        p0,
        _fd_features(calc, p0);
        inplace=false,
    )
    jac = NLSolversBase.jacobian!(od, p0)

    # Check consistency with numerical differentiation
    gtot = permutedims(gtot, [2, 3, 1, 4])
    jac = reshape(jac, size(gtot))

    _, n2, n2 = EDDP.feature_size(calc.cf)
    @test all(isapprox.(jac, gtot, atol=1e-5))


    # ### Check for stress
    s0 = zeros(9)
    od = NLSolversBase.OnceDifferentiable(
        x -> _fd_features_strain(calc, x),
        s0,
        _fd_features_strain(calc, s0);
        inplace=false,
    )
    sjac = reshape(
        NLSolversBase.jacobian!(od, s0),
        sum(EDDP.feature_size(calc.cf)),
        length(get_cell(calc)),
        3,
        3,
    )
    sd = calc.force_buffer.stotv
    sd = permutedims(sd, [3, 4, 1, 2])
    # Accuracy of this numerical differentiation is not so good...
    @test allclose(sjac, sd, atol=1e-4)
end


@testset "Forces" begin

    calc = _get_calc()
    EDDP._reinit_fb!(calc, "one-pass")
    ntot = EDDP.nfeatures(calc.cf)
    model = Chain(Dense(ones(1, ntot)))
    itf = EDDP.ManualFluxBackPropInterface(model)

    forces = copy(EDDP.get_forces(calc))
    stress = copy(EDDP.get_stress(calc))

    # Test the total force
    p0 = EDDP.get_positions(calc)
    od = OnceDifferentiable(x -> _fd_energy(calc, x), p0, _fd_energy(calc, p0))
    grad = NLSolversBase.gradient(od, p0)
    @test allclose(grad, -forces, atol=1e-6)

    # Test the total stress
    s0 = zeros(3, 3)[:]
    od = OnceDifferentiable(
        x -> _fd_strain(calc, x),
        s0,
        _fd_strain(calc, s0),
        inplace=false,
    )
    grad = NLSolversBase.gradient(od, s0) ./ volume(get_cell(calc))
    grad2 = grad
    @test allclose(grad, -vec(stress), atol=1e-3)

    # Test wrapper
    # NOTE Somehow this is needed here - possible BUG?
    vc = EDDP.VariableCellCalc(calc)
    epos = EDDP.get_positions(vc)
    eforce = copy(EDDP.get_forces(vc))

    od = OnceDifferentiable(
        x -> _fd_energy_vc(vc, x),
        epos,
        _fd_energy_vc(vc, epos);
        inplace=false,
    )
    grad = NLSolversBase.gradient(od, epos)
    @test allclose(grad, -eforce, atol=1e-4, rtol=1e-4)
end

#     calc = _get_calc()
#     EDDP._reinit_fb!(calc, "one-pass")
#     ntot = EDDP.nfeatures(calc.cf)    
#     model = Chain(Dense(ones(1, ntot)))
#     itf = EDDP.ManualFluxBackPropInterface(model)

#     forces = copy(EDDP.get_forces(calc))
#     stress = copy(EDDP.get_stress(calc))

#     # Test the total force
#     p0 = EDDP.get_positions(calc)
#     od = OnceDifferentiable(x -> _fd_energy(calc, x), p0, _fd_energy(calc, p0))
#     grad= NLSolversBase.gradient(od, p0)
#     @test allclose(grad, -forces, atol=1e-6)

#     p0 = EDDP.get_positions(calc)
#     od = OnceDifferentiable(x -> _fd_energy(calc, x), p0, _fd_energy(calc, p0))
#     grad= NLSolversBase.gradient(od, p0)
#     @test allclose(grad, -forces, atol=1e-6)


#     # Test the total stress
#     s0 = zeros(3,3)[:]
#     od = OnceDifferentiable(x -> _fd_strain(calc, x), s0, _fd_strain(calc, s0), inplace=false)
#     grad= NLSolversBase.gradient(od, s0) ./ volume(get_cell(calc))
#     grad2 = grad
#     @test allclose(grad, -vec(stress), atol=1e-3)

#     # Test wrapper
#     # NOTE Somehow this is needed here - possible BUG?
#     calc = _get_calc()
# #    calc.cell.positions[6] += 0.1
#     EDDP._reinit_fb!(calc, "one-pass")
#     calc_bak = deepcopy(calc) 
#     vc = EDDP.VariableCellCalc(calc)
#     epos = EDDP.get_positions(vc)
#     eforce = copy(EDDP.get_forces(vc))

#     od = OnceDifferentiable(x -> _fd_energy_vc(vc, x), epos, _fd_energy_vc(vc, epos);inplace=false)
#     vc_bak = deepcopy(vc) 
#     grad= NLSolversBase.gradient(od, epos)
#     @test allclose(grad, -eforce, atol=1e-4, rtol=1e-4)

#     od = OnceDifferentiable(x -> _fd_energy_vc(vc, x), epos, _fd_energy_vc(vc, epos);inplace=false)
#     vc_bak = deepcopy(vc) 
#     grad= NLSolversBase.gradient(od, epos)
#     @test allclose(grad, -eforce, atol=1e-4, rtol=1e-4)

#     vc = EDDP.VariableCellCalc(calc)
#     od = OnceDifferentiable(x -> _fd_energy_vc(vc, x), epos, _fd_energy_vc(vc, epos);inplace=false)
#     grad= NLSolversBase.gradient(od, epos)
#     @test allclose(grad, -eforce, atol=1e-4, rtol=1e-4)

#     calc.cell.positions == calc_bak.cell.positions

#     diff = 6e-6
#     p0[6] = -diff
#     e1 = _fd_energy(calc, p0)
#     p0[6] = diff
#     e2 = _fd_energy(calc, p0)
#     f = (e2 - e1) / 2 / diff

#     diff = 6e-6
#     p0[6] = -diff
#     e1 = _fd_energy(calc_bak, p0)
#     p0[6] = diff
#     e2 = _fd_energy(calc_bak, p0)
#     f = (e2 - e1) / 2 / diff



#     vc = EDDP.VariableCellCalc(calc_bak)
#     od = OnceDifferentiable(x -> _fd_energy_vc(vc, x), epos, _fd_energy_vc(vc, epos);inplace=false)
#     grad= NLSolversBase.gradient(od, epos)
#     @test allclose(grad, -eforce, atol=1e-4, rtol=1e-4)

# ##### Test zone ####


#     calc = _get_calc()
#     EDDP._reinit_fb!(calc, "one-pass")
#     vc = EDDP.VariableCellCalc(calc)
#     epos = EDDP.get_positions(vc)
#     eforce = copy(EDDP.get_forces(vc))
#     od = OnceDifferentiable(x -> _fd_energy_vc(vc, x), epos, _fd_energy_vc(vc, epos);inplace=false)
#     grad= NLSolversBase.gradient(od, epos)

# begin 
#     diff = 6e-6
#     epos[6] = -diff
#     e1 = _fd_energy_vc(vc, epos)
#     epos[6] = diff
#     e2 = _fd_energy_vc(vc, epos)
#     f = (e2 - e1) / 2 / diff
# end

# begin
#     diff = -6e-6
#     p0 = EDDP.get_positions(calc)
#     p0[6] = -diff
#     e1 = _fd_energy(calc, p0)
#     @show e1
#     p0[6] = diff
#     e2 = _fd_energy(calc, p0)
#     @show e2
#     f = (e2 - e1) / 2 / diff
# end