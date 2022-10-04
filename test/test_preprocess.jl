using EDDP
using CellBase
using Test

datadir = joinpath(splitdir(@__FILE__)[1], "data")
@testset "Preprocess" begin
    fpath = joinpath(datadir, "training/*.res")
    fpath = relpath(fpath, pwd())
    sc = EDDP.StructureContainer([fpath])
    @test isa(sc[1], Cell) 
    @test isa(sc[1:2], EDDP.StructureContainer) 
    @test length(sc) == 11
    sc_train, sc_test = EDDP.train_test_split(sc, ratio_test=0.5)
    @test length(sc_train) == 5
    fc = EDDP.FeatureContainer(sc, EDDP.FeatureOptions(elements=[:B]))
    fc = EDDP.FeatureContainer(sc)
    @test length(fc) == 11
    fc_train, fc_test = EDDP.train_test_split(fc, ratio_test=0.5)
    @test length(fc_train) == 5

    train_data = EDDP.training_data(fc, ratio_test=0.5)

    # Test data scaling
    xdata = [rand(10, 10) for _ in 1:10]
    xtot = reduce(hcat, xdata)
    xt = fit(StatsBase.ZScoreTransform, xtot[2:end, :], dims=2)

    EDDP.transform_x!(xt, xdata)
    @test std(reduce(hcat, xdata)[end, :]) ≈ 1 atol=1e-7
    @test mean(reduce(hcat, xdata)[end, :]) ≈ 0 atol=1e-7

end