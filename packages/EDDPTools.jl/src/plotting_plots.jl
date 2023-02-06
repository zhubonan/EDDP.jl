using EDDP
using EDDP: load_ensemble, load_features, load_structures, resample_mae_rmse
using EDDP: enthalpyandvolume, relativeabsoluteerror, TrainingResults
using EDDP: ComputedRecord, PhaseDiagram, get_e_above_hull, compute_specie_separations, gather_minsep_stats

using Plots: scatter, plot!, histogram, @layout, grid
using LaTeXStrings
using Glob



"""
    plot_2d_hull(phased;threshold=0.1)

Plots 2D convex hull from a PhaseDiagram
"""
function make_binary_hull_plot(phased; max_above_hull=0.1)
    plot_data = EDDP.get_2d_plot_data(phased; threshold=max_above_hull)
    comp_label = L"$\mathrm{%$(phased.elements[2])_x%$(phased.elements[1])_{1-x}}$"
    p = scatter(
        plot_data.x,
        plot_data.y,
        markersize=3,
        markeralpha=0.3,
        label=nothing,
        xlabel=comp_label,
        ylabel="Formation Energy (eV / Atom)",
    )
    plot!(
        p,
        plot_data.stable_x,
        plot_data.stable_y,
        marker=(:diamond, 5),
        linecolor=:red,
        linewidth=2,
        label="Stable",
    )
    p
end



"""
    plot_minsep_distribution(workdir::AbstractString, gen, pair::Pair{Symbol, Symbol};xmax=6., pkwargs...)

Plot MINSEP distributions for a work directory.
"""
function plot_minsep_distribution(workdir::AbstractString, gen, pair::Pair{Symbol, Symbol};xmax=6., pkwargs...)
    l = @layout grid(length(gen), 1)

    pbase = relpath(workdir, pwd())

    files = glob(joinpath(pbase, "gen*-dft/*.res"))
    rpat = ["gen$i-" for i in gen]

    # Include only files that will be used
    files = filter(x -> any(y -> contains(x, y), rpat), files)
    cells = map(read_res, files);

    # Index for each generation
    gens = Dict(i => findall(x -> contains(x, "gen$i"), files) for i in gen)

    # Compute the separations
    species_seps = compute_specie_separations.(cells);

    # Compose the figures
    figs = []
    for g in gen
        xlabel = g == gen[end] ? L"Distance ($\AA$)" : ""
        minsep, _ = gather_minsep_stats(species_seps[gens[g]]);
        p = Plots.histogram(minsep[pair], xlabel=xlabel, xlim=(0, xmax), bins=LinRange(0, xmax, 100), label="gen$g")
        push!(figs, p)
    end
    Plots.plot(figs..., layout=l, legend=true, yticks=false, pkwargs...)
end

