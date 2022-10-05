using EDDP
using CellBase
using Test
using StatsBase

datadir = joinpath(splitdir(@__FILE__)[1], "data")
@testset "Preprocess" begin
    fpath = joinpath(datadir, "training/*.res")
    fpath = relpath(fpath, pwd())
    sc = EDDP.StructureContainer([fpath])
    # test splitting
    @test isa(sc[1], Cell) 
    @test isa(sc[1:2], EDDP.StructureContainer) 
    @test length(sc) == 11

    sc1, sc2 = split(sc, 1, 2)
    @test length(sc1) == 1
    @test length(sc2) == 2

    sc1, sc2 = split(sc[1:10], 0.1, 0.2)
    @test length(sc1) == 1
    @test length(sc2) == 2

    sc_train, sc_test = EDDP.train_test_split(sc, ratio_test=0.5)
    @test length(sc_train) == 6
    fc = EDDP.FeatureContainer(sc, EDDP.FeatureOptions(elements=[:B]))
    # Default FeatureOPtions
    fc = EDDP.FeatureContainer(sc)
    @test length(fc) == 11
    fc_train, fc_test = EDDP.train_test_split(fc, ratio_test=0.5)
    @test length(fc_train) == 6

    train_data = EDDP.training_data(fc, ratio_test=0.5)

    # Test data scaling
    xdata = [rand(10, 10) for _ in 1:10]
    xtot = reduce(hcat, xdata)
    xt = StatsBase.fit(StatsBase.ZScoreTransform, xtot[2:end, :], dims=2)

    EDDP.transform_x!(xt, xdata)
    @test std(reduce(hcat, xdata)[end, :]) ≈ 1 atol=1e-7
    @test mean(reduce(hcat, xdata)[end, :]) ≈ 0 atol=1e-7

    # Test standardisation
    fc1, fc2 = split(fc[1:10], 5, 3;shuffle=false)
    EDDP.standardize!(fc1, fc2)
    @test fc.xt === nothing
    @test fc.yt === nothing
    @test fc1.fvecs[1] != fc.fvecs[1]
    @test !isnothing(fc1.xt)
    @test !isnothing(fc2.xt)
    @test fc1.xt === fc2.xt
    @test fc1.yt === fc2.yt
    @test mean(reduce(hcat, fc1.fvecs)[2, :]) ≈ 0. atol=1e-8
    @test !isapprox(mean(reduce(hcat, fc2.fvecs)[2, :]),  0.; atol=1e-8) 

end