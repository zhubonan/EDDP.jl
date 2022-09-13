module EDDP

greet() = print("Hello World!")
using CellBase
using CellBase: read_castep
import CellBase
using StatsBase: mean
export mean

# External
include("nnls.jl")
include("potential.jl")
include("backprop.jl")
include("gradient.jl")
include("nntools.jl")
include("lmsolve.jl")
include("training.jl")
include("preprocessing.jl")
include("evaluate.jl")
include("tools.jl")

export Lattice, reciprocal, cellmat, cellvecs, cellpar, wrap!, volume, frac_pos, lattice
export distance_between, distance_squared_between, displace!, clip, Cell, supercell
export distance_matrix, laplacian_matrix, nmodules, find_modules
export get_cell, get_forces, get_energy, get_stress, generate_vc, CellFeature, CellWorkSpace, CellCalculator
export get_positions, set_positions!, set_cell!

end # module