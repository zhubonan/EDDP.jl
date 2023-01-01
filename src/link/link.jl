#=
Code for iteratively building the model
=#
import Base
using Parameters
using JSON

const XT_NAME="xt"
const YT_NAME="yt"
const FEATURESPEC_NAME="cf"


@with_kw mutable struct BuilderState
    iteration::Int=0
    workdir::String
    seedfile::String
    seedfile_calc::String=seedfile
    max_iterations::Int=5
    per_generation::Int=100
    per_generation_threshold::Float64=0.98
    shake_per_minima::Int=10
    build_timeout::Float64=1.
    shake_amp::Float64=0.02
    shake_cell_amp::Float64=0.02
    n_parallel::Int=1
    mpinp::Int=2
    n_initial::Int=1000
    dft_mode::String="castep"
    dft_kwargs::NamedTuple=NamedTuple()
    relax_extra_opts::Dict{Symbol,Any} = Dict()
    rss_pressure_gpa::Float64=0.1
    rss_niggli_reduce::Bool=true
    core_size::Float64=1.0
    ensemble_std_min::Float64=0.0
    ensemble_std_max::Float64=-1.0
end

abstract type AbstractTrainer end

@with_kw mutable struct LocalLMTrainer <: AbstractTrainer
    energy_threshold::Float64=10.
    nmax::Int=3000
    nmodels::Int=256
    user_test_for_ensemble::Bool=true
    max_iter::Int=300
    "number of hidden nodes in each layer"
    n_nodes::Vector{Int}=[8]
    earlystop::Int=30
    show_progress::Bool=true
    "Store the data used for training in the archive"
    store_training_data::Bool=true
    rmse_threshold::Float64=0.5
    training_mode::String="manual_backprop"
    training_kwargs::NamedTuple=NamedTuple()
    train_split::NTuple{3, Float64}=(0.8, 0.1, 0.1)
    use_test_for_ensemble::Bool=true
    save_each_model::Bool=true
end


struct Builder{M<:AbstractTrainer} 
    state::BuilderState
    cf::CellFeature
    trainer::M
    cf_embedding
    # Set the iteration states
    function Builder(state, cf, trainer, cf_embedding=nothing)
        builder = new{typeof(trainer)}(state, cf, trainer, cf_embedding)
        _set_iteration!(builder)
        builder_uuid(builder)
        builder
    end
end

function Base.show(io::IO, ::MIME"text/plain", bu::Builder)
    println(io, "Builder")
    println(io, "  Working directory: $(bu.state.workdir) ($(abspath(bu.state.workdir)))")
    println(io, "  Iteration: $(bu.state.iteration)")
    println(io, "  Seed file: $(bu.state.seedfile)")
end

Base.show(io::IO, bu::Builder) = Base.show(io, MIME("text/plain"), bu)


"""
    _set_iteration!(builder::Builder)

Fastword to the iteration by checking existing ensemble files
"""
function _set_iteration!(builder::Builder)
    # Set the iteration number
    for iter in 0:builder.state.max_iterations
        builder.state.iteration = iter
        if !has_ensemble(builder, iter) 
            break
        end
    end
end


function link!(builder::Builder 
    )
    state = builder.state
    while state.iteration <= state.max_iterations
        step!(builder
        )
    end
end

ensure_dir(args...) = isdir(joinpath(args...)) || mkdir(joinpath(args...)) 

"""
Run a step step for the Builder
"""
function step!(bu::Builder)
    iter = bu.state.iteration
    if has_ensemble(bu, iter) 
        bu.state.iteration += 1
        return bu
    end
    # Generate new structures
    _generate_random_structures(bu, iter)

    # Run external code for 
    if !is_training_data_ready(bu, iter)
        @info "Starting energy calculations for iteration $iter."
        flag = _run_external(bu)
        flag || throw(ErrorException("Cannot find external code to run for generating training data"))
    end
    ns = nstructures(bu, iter)
    @info "Number of new structures in iteration $(iter): $ns"

    # Retrain model
    @info "Starting training for iteration $iter."
    ensemble, train_labels, test_labels, valid_labels = _perform_training(bu)
    savepath = joinpath(bu.state.workdir, "ensemble-gen$(iter).jld2")
    save_as_jld2(savepath, ensemble)

    # Record the labels of the structures and more information
    jldopen(savepath, "r+") do fh
        fh["train_labels"] = train_labels 
        fh["test_labels"] = test_labels 
        fh["valid_labels"] = valid_labels 
        fh["builder_uuid"] = builder_uuid(bu)
        fh["cf"] = bu.cf
    end

    bu.state.iteration += 1
    bu
end

"""
    _generate_random_structures(bu::Builder, iter)

Generate random structure (if needed) as training data for the `Builder`.
"""
function _generate_random_structures(bu::Builder, iter)
    # Generate new structures
    outdir = _input_structure_dir(bu)
    ensure_dir(outdir)
    ndata = length(glob_allow_abs(joinpath(outdir, "*.res")))
    if iter == 0
        # First cycle generate from the seed without relaxation
        # Sanity check - are we definitely overfitting?
        if nfeatures(bu.cf) > bu.state.n_initial 
            @warn "The number of features $(nfeature(bu.cf)) is larger than the initial training size!"
        end
        # Generate random structures
        nstruct = bu.state.n_initial - ndata
        if nstruct > 0
            @info "Genearating $(nstruct) initial training structures."
            build_random_structures(bu.state.seedfile, outdir;
            n=nstruct
            )
        end
    else
        # Subsequent cycles - generate from the seed and perform relaxation
        # Read ensemble file
        efname = joinpath(bu.state.workdir, "ensemble-gen$(iter-1).jld2")
        @assert isfile(efname) "Ensemble file $(efname) does not exist!"
        ensemble = load_from_jld2(efname, EnsembleNNInterface)
        nstruct = bu.state.per_generation - ndata
        if nstruct > 0 
            @info "Generating $(nstruct) training structures for iteration $iter."
            # Generate data sets
            run_rss(bu.state.seedfile, ensemble, bu.cf; 
                core_size=bu.state.core_size,
                ensemble_std_max=bu.state.ensemble_std_max,
                ensemble_std_min=bu.state.ensemble_std_min,
                max=nstruct, 
                outdir=outdir,
                pressure_gpa=bu.state.rss_pressure_gpa,
                niggli_reduce_output=bu.state.rss_niggli_reduce
            )
            # Shake the generate structures
            @info "Shaking generated structures."
            outdir = joinpath(bu.state.workdir, "gen$(iter)")
            shake_res(
                collect(glob_allow_abs(joinpath(outdir, "*.res"))), 
                bu.state.shake_per_minima, 
                bu.state.shake_amp, 
                bu.state.shake_cell_amp
                )
        end
    end
end


"Directory for input structures"
_input_structure_dir(bu::Builder)  = joinpath(bu.state.workdir, "gen$(bu.state.iteration)")
"Directory for output structures after external calculations"
_output_structure_dir(bu::Builder)  = joinpath(bu.state.workdir, "gen$(bu.state.iteration)-dft")


"""
Run external code for generating training data
"""
function _run_external(bu::Builder)
    ensure_dir(_output_structure_dir(bu))
    if bu.state.dft_mode=="disp-castep"
        run_disp_castep(
            _input_structure_dir(bu), _output_structure_dir(bu), bu.state.seedfile_calc;
            threshold=bu.state.per_generation_threshold,
            bu.state.dft_kwargs...
        )
        return true
    elseif bu.state.dft_mode == "pp3"
        run_pp3_many(joinpath(bu.state.workdir, ".pp3_work"), 
            _input_structure_dir(bu), _output_structure_dir(bu), bu.state.seedfile_calc;n_parallel=bu.state.n_parallel, bu.state.dft_kwargs...)
        return true
    elseif bu.state.dft_mode == "castep"
        run_crud(
            bu.state.workdir, 
            _input_structure_dir(bu), _output_structure_dir(bu);mpinp=bu.state.mpinp, bu.state.n_parallel, bu.state.dft_kwargs...)
        return true
    end
    return false
end

"""
Carry out training and save the ensemble as a JLD2 archive.
"""
function _perform_training(bu::Builder{M}) where {M<:LocalLMTrainer}
    t = bu.trainer
    ## Training new models
    dirs = [
        joinpath(bu.state.workdir, "gen$(iter)-dft/*.res") for iter in 0:bu.state.iteration
    ]
    @info "Training data from: $(dirs)"
    cf = bu.cf
    sc = EDDP.StructureContainer(dirs, threshold=t.energy_threshold)
    fc = EDDP.FeatureContainer(sc, cf;nmax=t.nmax);
    train, test, valid = split(fc, t.train_split...)
    model = EDDP.ManualFluxBackPropInterface(cf, t.n_nodes...;
                xt=train.xt, yt=train.yt, apply_xt=false, embedding=bu.cf_embedding)
    ensemble = EDDP.train_multi_threaded(EDDP.reinit(model), 
                prefix="gen$(bu.state.iteration)",
                train, test;nmodels=t.nmodels, 
                show_progress=t.show_progress,
                earlystop=t.earlystop,
                save_each_model=t.save_each_model,
                use_test_for_ensemble=t.use_test_for_ensemble)
    return ensemble, train.labels, test.labels, valid.labels
end


function builder_uuid(workdir='.')
    fname = joinpath(workdir, ".eddp_builder")
    if isfile(fname)
        uuid = open(fname) do fh
            chomp(readline(fh))
        end
    else 
        uuid = string(uuid4())
        open(fname, "w") do fh
            write(fh, uuid)
            write(fh, "\n")
        end
    end
    uuid
end

builder_uuid(bu::Builder) = builder_uuid(bu.state.workdir)

"""
    _disp_get_completed_jobs(project_name)

Get the number of completed jobs as well as the total number of jobs under a certain project.
NOTE: this requires `disp` to be avaliable in the commandline.
"""
function _disp_get_completed_jobs(project_name)
    cmd = `disp db summary --singlepoint --project $project_name --json`
    json_string = readchomp(pipeline(cmd))
    data = parse_disp_output(json_string)
    ncomp = get(data, "COMPLETED", 0) 
    nall = get(data, "ALL", -1)
    ncomp, nall
end


"""
Run relaxation through DISP
"""
function run_disp_castep(indir, outdir, seedfile;categories, priority=90, project_prefix="eddp.jl",
                         monitor_only=false,
                         watch_every=60,
                         threshold=0.98,
                         kwargs...)

    file_pattern = joinpath(indir, "*.res")
    seed = splitext(seedfile)[1]
    # Setup the inputs
    project_name = joinpath(gethostname(), project_prefix, abspath(indir)[2:end])
    seed_stem = splitext(basename(seedfile))[1]
    cmd=`disp deploy singlepoint --seed $seed_stem --base-cell $seed.cell --param $seed.param --cell $file_pattern --project $project_name --priority $priority` 

    # Define the categories
    for category in categories
        push!(cmd.exec, "--category")
        push!(cmd.exec, category)
    end

    if !monitor_only
        # Check if jobs have been submitted already
        ncomp, nall = _disp_get_completed_jobs(project_name)
        if nall == -1
            @info "Command to be run $(cmd)"
            run(cmd)
        else
            @info "There are already $(ncomp) out of $(nall) jobs completed - monitoring the progress next."
        end
    else
        @info "Not launching jobs - only watching for completion"
    end

    # Start to monitor the progress
    @info "Start watching for progress"
    sleep(1)
    while true
        ncomp, nall = _disp_get_completed_jobs(project_name)
        if ncomp / nall > threshold
            @info " $(ncomp)/$(nall) calculation completed - moving on ..."
            break
        else
            @info "Completed calculations: $(ncomp)/$(nall) - waiting ..."
        end
        sleep(watch_every)
    end
    # Pulling calculations down
    isdir(outdir) || mkdir(outdir)
    cmd = Cmd(`disp db retrieve-project --project $project_name`, dir=outdir)
    run(cmd)
    @info "Calculation results pulled into $outdir."
end


"""
    run_pp3_many(workdir, indir, outdir, seedfile; n_parallel=1, keep=false)

Use PP3 for singlepoint calculation - launch many calculations in parallel.
"""
function run_pp3_many(workdir, indir, outdir, seedfile; n_parallel=1, keep=false)
    files = glob_allow_abs(joinpath(indir, "*.res"))
    ensure_dir(workdir)
    for file in files
        working_path = joinpath(workdir, splitpath(file)[end])
        cp(file, working_path, force=true)
        try
            run_pp3(working_path, seedfile, joinpath(outdir, splitpath(file)[end]))
        catch error
            if typeof(error) <: ArgumentError
                @warn "Failed to calculate energy for $(file)!"
                continue
            end
            throw(error)
        end
        if !keep
            for suffix in [".cell", ".conv", "-out.cell", ".pp", ".res"]
                rm(swapext(working_path, suffix))
            end
        end
    end
end


"""
    run_pp3(file, seedfile, outpath)

Use `pp3` for single point calculations.
"""
function run_pp3(file, seedfile, outpath)
    if endswith(file, ".res")
        cell = CellBase.read_res(file)
        # Write as cell file
        CellBase.write_cell(swapext(file, ".cell"), cell)
    else
        cell = CellBase.read_cell(file)
    end
    # Copy the seed file
    cp(swapext(seedfile, ".pp"), swapext(file, ".pp"), force=true)
    # Run pp3 relax
    # Read enthalpy
    enthalpy = 0.0
    pressure = 0.0
    for line in eachline(pipeline(`pp3 -n $(splitext(file)[1])`))
        if contains(line, "Enthalpy")
            enthalpy = parse(Float64, split(line)[end])
        end
        if contains(line, "Pressure")
            pressure = parse(Float64, split(line)[end])
        end
    end
    # Write res
    cell.metadata[:enthalpy] = enthalpy
    cell.metadata[:pressure] = pressure
    cell.metadata[:label] = stem(file)
    CellBase.write_res(outpath, cell)
    cell
end


"""
    parse_disp_output(json_string)

Parse the output of `disp db summary`
"""
function parse_disp_output(json_string)
    data = Dict{String, Int}()
    if contains(json_string, "No data")
        return data
    end
    tmp = JSON.parse(json_string)
    for (x, y) in tmp
        # How to unpack this way due to nested multi-index
        if contains(x, "RES")
            data["RES"] = first(values(first(values(y))))
        elseif contains(x, "ALL")
            data["ALL"] = first(values(first(values(y))))
        elseif contains(x, "COMPLETED")
            data["COMPLETED"] = first(values(first(values(y))))
        end
    end
    data
end


"""
Summarise the status of the project
"""
function summarise(builder::Builder)
    opts = builder.state
    subpath(x) = joinpath(opts.workdir, x)
    println("Workding directory: $(opts.workdir)")
    println("Seed file: $(opts.seedfile)")

    function print_res_count(path)
        nfiles = length(glob_allow_abs(joinpath(path, "*.res")))
        println("  $(path): $(nfiles) structures")
        nfiles
    end

    total_dft = 0
    for i=0:opts.max_iterations
        println("iteration $i")

        path = subpath("gen$i")
        print_res_count(path)

        path = subpath("gen$(i)-dft")
        total_dft += print_res_count(path)
    end
    println("Total training structures: $(total_dft)")
end


raw"""
    walk_forward_tests(builder::Builder)

Perform walk forward tests - test if the data of generation ``N`` can be predicted by the model 
from generation ``N-1``, and compare it with the results using model from generation ``N`` itself. 
"""
function walk_forward_tests(bu::Builder;print_results=false, fc_show_progress=false, check_training_data=false)
    trs = []
    for iter in 0:bu.state.iteration-1
        if check_training_data
            is_training_data_ready(bu, iter+1) || continue
        else
            if nstructures_calculated(bu, iter+1) < 1
                continue
            end
        end
        has_ensemble(bu, iter) || break
        @info "Loading features of generation $(iter+1) to test for generation $(iter)..."
        fc = load_features(bu, iter + 1;show_progress=fc_show_progress)
        ensemble = load_ensemble(bu, iter)
        tr = EDDP.TrainingResults(ensemble, fc)
        push!(trs, tr)
        if print_results
            println("Trained model using iteration 0-$iter applied for iteration $(iter+1):")
            println(tr)
        end
    end
    trs
end

function has_ensemble(bu::Builder, iteration=bu.state.iteration)
    isfile(joinpath(bu.state.workdir, "ensemble-gen$(iteration).jld2") )
end

function load_ensemble(bu::Builder, iteration=bu.state.iteration)
    EDDP.load_from_jld2(ensemble_name(bu, iteration), EDDP.EnsembleNNInterface) 
end

ensemble_name(bu, iteration=bu.state.iteration) = joinpath(bu.state.workdir, "ensemble-gen$(iteration).jld2")

function is_training_data_ready(bu::Builder, iteration=bu.state.iteration)
    isdir(joinpath(bu.state.workdir, "gen$(iteration)-dft")) || return false
    ndft = nstructures_calculated(bu, iteration)
    if iteration == 0
        nexpected = bu.state.n_initial
    else
        nexpected = bu.state.per_generation * (bu.state.shake_per_minima + 1)
    end
    if ndft / nexpected > bu.state.per_generation_threshold
        return true
    end
    return false
end

nstructures(bu::Builder, iteration) =  length(glob_allow_abs(joinpath(bu.state.workdir, "gen$(iteration)/*.res")))
nstructures_calculated(bu::Builder, iteration) =  length(glob_allow_abs(joinpath(bu.state.workdir, "gen$(iteration)-dft/*.res")))

function load_structures(bu::Builder, iteration::Vararg{Int})
    dirs = [
        joinpath(bu.state.workdir, "gen$(iter)-dft/*.res") for iter in iteration
    ]
    sc = EDDP.StructureContainer(dirs, threshold=bu.trainer.energy_threshold)
    return sc 
end
load_structures(bu::Builder) = load_structures(bu, 0:bu.state.iteration)
load_structures(bu::Builder, iteration) = load_structures(bu, iteration...)

"""
    load_features(bu::Builder, iteration...)

Loading features for specific iterations.   
"""
function load_features(bu::Builder, iteration::Vararg{Int};show_progress=true)
    sc = load_structures(bu, iteration...;)
    return EDDP.FeatureContainer(sc, bu.cf;nmax=bu.trainer.nmax, show_progress);
end

load_features(bu::Builder;kwargs...) = load_features(bu, 0:bu.state.iteration;kwargs...)
load_features(bu::Builder, iteration;kwargs...) = load_features(bu, iteration...;kwargs...)

