"""
Read a cell file
"""
function read_cell(fname::AbstractString)
    lines = readlines(fname)
    read_cell(lines)
end

"Clean lines by removing new line symbols and comments"
function clean_lines(lines_in::Vector{String})
    lines_out = String[]
    for line in lines_in
        tmp = strip(line)
        if length(tmp) == 0
            continue
        end
        icomment = findnext('#', tmp, 1)
        if icomment === nothing
            push!(lines_out, string(tmp))
        elseif icomment == 1
            continue
        else
            push!(lines_out, string(strip(tmp[1:icomment-1])))
        end
    end
    lines_out
end

"""
Read content of a cell file
"""
function read_cell(lines_in::Vector{T}) where T<:AbstractString

    lines = clean_lines(lines_in)
   
    # read cell vectors
    block = find_block(lines, "LATTICE_CART")
    if length(block) > 0
        cellmat = copy(read_num_block(block, 3, column_major=true))
    else
        cell_par = Array{Float64}(undef, 6)
        block = find_block(lines, "LATTICE_ABC")
        @assert length(block) > 0 "Neither lattice_cart or lattice_abc are present"
        cell_par_raw = read_num_block(block, 3)
        cell_par[1:3] = cell_par_raw[1, :]
        cell_par[4:6] = cell_par_raw[2, :]
        cellmat = cellpar2vec(cell_par)
    end

    # read positions
    positions = Vector{Float64}[]
    is_abs = false
    block = find_block(lines, "POSITIONS_ABS")
    if length(block) > 0
        is_abs = true
    else
        block = find_block(lines, "POSITIONS_FRAC")
    end
    pos_block = String[]
    ion_names = Symbol[]
    for line in block
        sline = split(line)
        push!(positions, map(x -> parse(Float64, x), sline[2:4]))
        push!(ion_names, Symbol(sline[1]))
    end

    # The positions are stored as column vector matrix
    posmat = hcat(positions...)
    if is_abs
        positions_frac = convert_frac_pos(cellmat, posmat)
    else
        posmat = cellmat * posmat
    end

    # Read CASTEP keys
    # kw_settings = KW()
    # for line in filter_block(lines)
    #     m = match(r"^(\w+)[ :=]+(.*)$", line) 
    #     if !isnothing(m)
    #         kw_settings[Symbol(m.captures[1])] = m.captures[2]
    #     end
    # end
        
    return cellmat, posmat, ion_names
end

function read_cell(::Type{T}, fname) where T
    cellmat, posmat, species = read_cell(fname)
    if T == Cell
        lattice = Lattice(cellmat)
        return Cell(lattice, speices, posmat)
    end
end


"""
Read in cell 
"""
function read_seed(fname::String)
    lines = readlines(fname)
    read_seed(lines)
end


"""
Read seed with the label parsed. At this stage no explansions are done
"""
function read_seed(lines_in::Vector{T}) where T<:AbstractString

    cell_structure = read_cell(lines_in)
    # read positions

    is_abs = false
    block = find_block(lines_in, "POSITIONS_ABS")
    if !isempty(block)
        is_abs = true
    else
        block = find_block(lines_in, "POSITIONS_FRAC")
    end
    ion_tags = parse_taglines(block)

    # Read global tags in the format #KEY=<SOMETHING>
    global_tags = Dict{Symbol, Any}()
    for line in lines_in
        m = match(r"^#(\w+)=(.*)$", line)
        if !isnothing(m)
            global_tags[Symbol(m.captures[1])] = strip(m.captures[2])
        end
    end

    return cell_structure, ion_tags, global_tags
end

"""
Parse the tag line, return a dictionary of the
tagline is in the form of <ion_set_name> % KEY=VALUE KEY=VALUE
"""
function _parse_tagline(i, line)
    num_tags = ["POSAMP", "MINAMP", "ANGAMP", "XAMP", "ZAMP", "RAD"]
    flag_tags = ["FIX", "NOMOVE", "PERM", "ADATOM", "ATHOLE"]
    not_implemented = ["COORD"]

    tokens = split(line, "%", limit=2)
    has_settings = false
    if length(tokens) > 1
        ion_set_name = strip(tokens[1])
        tokens = split(tokens[2])
        has_settings = true
    else
        if isempty(tokens[1])
            ion_set_name = "Ion-" * string(i)
        else
            ion_set_name = strip(tokens[1])
        end
    end

    out_dict = Dict{Symbol, Any}(:ion_set_name => ion_set_name)

    # Read the tokens
    if has_settings
        for token in tokens
            m = match(r"(\w+)=(.+)", token)
            if !isnothing(m)
                key = m.captures[1]
                value = m.captures[2]
                out_dict[Symbol(key)] = parse(Float64, value)
            elseif token in flag_tags
                out_dict[Symbol(token)] = true
            else
                throw(ErrorException("Token \"$(token)\" not understood"))
            end
        end
    end
    return out_dict
end

"""
Parse tag lines, return a vector of dictionary containing parsed tags 
"""
function parse_taglines(lines::Vector{T}) where T<:AbstractString
    tags = []
    i = 0
    for line in lines
        line = strip(line)
        if startswith(line, "#"); continue; end
        tokens = split(line, "#")
        if length(tokens) <= 1
            continue
        else
            i += 1
            ltmp = tokens[2]
            push!(tags, _parse_tagline(i, ltmp))
        end
    end
    return tags
end

"""
Read a numerical block in the form of a vector of String
"""
function read_num_block(lines::Vector{T}, span::Int; ntype::Type=Float64, column_major=false) where T<:AbstractString
    if column_major
        block = Array{ntype}(undef, (span, length(lines)))
        for (n, line) in enumerate(lines)
            block[:, n] = map(p -> parse(ntype, p), split(line))
        end
    else
        block = Array{ntype}(undef, (length(lines), span))
        for (n, line) in enumerate(lines)
            block[n, :] = map(p -> parse(ntype, p), split(line))
        end
    end
    return block
end


"""
Find the block with given name, return a Vector of the lines
Comments are skipped
"""
function find_block(lines, block_name)
    in_block = false
    block_lines = String[]
    b_start = "%BLOCK " * block_name
    bname = ""
    for line in lines
        # Skip any comment line
        if startswith(line, "#")
            continue
        elseif startswith(uppercase(line), b_start)
            current_block_name = split(line)[2]
            in_block = true
        elseif in_block && startswith(uppercase(line), "%ENDBLOCK")
            bname = split(line)[2]
            @assert bname == block_name "Block <$(block_name)> ends as <$(bname)>"
            break
        elseif in_block
            push!(block_lines, line)
        end
    end
    return block_lines
end

"""
Get rid of blocks 
"""
function filter_block(lines)
    out_lines = String[]
    in_block = false
    for line in lines
        # Skip any comment line
        if startswith(uppercase(line), "%BLOCK")
            in_block = true
        elseif in_block && startswith(uppercase(line), "%ENDBLOCK")
            in_block = false
        elseif !in_block
            push!(out_lines, line)
        end
    end
    return out_lines
end

"""
Filter away block names contained in only
"""
function filter_block(lines, only::Vector{T}) where T<:AbstractString
    out_lines = String[]
    in_block = false
    bname = ""
    only_upper = [uppercase(x) for x in only]
    for line in lines
        # Skip any comment line
        if startswith(uppercase(line), "%BLOCK")
            bname = split(line)[2]
            if bname in only
                in_block = true
            else
                push!(out_lines, line)
            end
        elseif in_block && startswith(uppercase(line), "%ENDBLOCK")
            @assert split(line)[2] == bname "Incomplete block <$bname>, ends with $line"
            in_block = false
        elseif !in_block
            push!(out_lines, line)
        end
    end
    return out_lines
end