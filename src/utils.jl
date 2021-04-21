"""
    elem_basis(i, n)
    
Returns a vector corresponding to the ith elementary basis in dimension n. 
"""
elem_basis(i, n) = [k == i ? 1.0 : 0.0 for k in 1:n]

"""
    compute_linear_objective(network, x, coeffs)

Helper function to compute a linear objective given a network, input, and coefficients. This function 
    just passes the input through the network then dots the output with the coefficients.
"""
compute_linear_objective(network, x, coeffs) = dot(coeffs, NeuralVerification.compute_output(network, x))

"""
    split_cell(cell::Hyperrectangle)
Split a hyperrectangle into multiple hyperrectangles. We currently pick the largest dimension 
and split along that. 
"""

function split_cell(cell::Hyperrectangle)
    lbs, ubs = low(cell), high(cell)
    largest_dimension = argmax(ubs .- lbs)
    # have a vector [0, 0, ..., 1/2 largest gap at largest dimension, 0, 0, ..., 0]
    delta = elem_basis(largest_dimension, length(lbs)) * 0.5 * (ubs[largest_dimension] - lbs[largest_dimension])
    cell_one = Hyperrectangle(low=lbs, high=(ubs .- delta))
    cell_two = Hyperrectangle(low=(lbs .+ delta), high=ubs)
    return [cell_one, cell_two]
end

"""
    split_multiple_times(cell, n)

Helper function to split a cell multiple times. It applies split_cell n times 
    resulting in a queue with n+1 cells. The first cell to be split is the last to be split again 
    since we use a queue (so we don't just repeatedly split the same cell).
"""
function split_multiple_times(cell::Hyperrectangle, n)
    q = Queue{Hyperrectangle}()
    enqueue!(q, cell)
    for i = 1:n
        new_cells = split_cell(dequeue!(q))
        enqueue!(q, new_cells[1])
        enqueue!(q, new_cells[2])
    end
    return q
end

"""
    dist_to_zonotope_p(zonotope::Zonotope, point, p)

    A helper function which finds the distance for an arbitrary p-norm norm between a 
        zonotope and a point. This is defined as 
    inf_x ||x - point||_p s.t. x in zonotope
"""
function dist_zonotope_point(zonotope::Zonotope, point, p)
    G, c = zonotope.generators, zonotope.center
    n, m = size(G)
    x = Variable(m) # points in the hypercube defining the zonotope
    obj = norm(G * x + c - point, p)
    prob = minimize(obj, [x <= 1.0, x >= -1.0])
    solve!(prob, Mosek.Optimizer(LOG=0))
    @assert prob.status == OPTIMAL "Solve must result in optimal status"
    return prob.optval
end

"""
    dist_to_zonotope_p(zonotope::Zonotope, polytope, p)

    A helper function which finds the distance for an arbitrary p-norm norm between a 
        zonotope and a polytope. This is defined as 
    inf_x,y ||x - y||_p s.t. x in zonotope and y in polytope 
"""
function dist_zonotope_polytope(zonotope::Zonotope, A, b, p)
    G, c = zonotope.generators, zonotope.center
    n, m = size(G)
    x = Variable(m) # points in the hypercube defining the zonotope
    y = Variable(size(A, 2)) # points in the polytope 
    obj = norm(G * x + c - y, p)
    prob = minimize(obj, [x <= 1.0, x >= -1.0, A*y <= b])
    solve!(prob, Mosek.Optimizer(LOG=0))
    @assert prob.status == OPTIMAL "Solve must result in optimal status"
    return prob.optval <= NeuralVerification.TOL[] ? 0.0 : prob.optval
end

"""
    dist_zonotope_polytope_linf(zonotope::Zonotope, A, b)

Find the minimum distance between a zonotope and a polytope measured by the linf norm.
This is formulated as an LP

"""
function dist_zonotope_polytope_linf(zonotope::Zonotope, A, b; solver=Gurobi.Optimizer)
    G, c = zonotope.generators, zonotope.center
    n, m = size(G)
    model = Model(with_optimizer(solver, gurobi_env, OutputFlag=0))
    
    # Introduce x in the basis of the zonotope, y in the polytope 
    x = @variable(model, [1:m])
    z = G * x + c
    @constraint(model, x .>= -1.0)
    @constraint(model, x .<= 1.0)
    
    y = @variable(model, [1:n])
    @constraint(model, A*y .<= b)

    # Now, introduce a variable for our l-inf norm
    t = @variable(model)
    @constraint(model, t .>= y - z)
    @constraint(model, t .>= z - y)
    @objective(model, Min, t)

    optimize!(model)
    @assert termination_status(model) == OPTIMAL "Solve must result in optimal status"
    return value(t) # should this add a TOL[] be here?
end

"""
    dist_polytope_zonotope_l1(zonotope::Zonotope, A, b; solver=Gurobi.Optimizer)

Find the minimum distance between a zonotope and a polytope measured by the l1 norm.
This is formulated as an LP
"""
function dist_zonotope_polytope_l1(zonotope::Zonotope, A, b; solver=Gurobi.Optimizer)
    G, c = zonotope.generators, zonotope.center
    n, m = size(G)
    model = Model(with_optimizer(solver, gurobi_env, OutputFlag=0))
    
    # Introduce x in the basis of the zonotope, y in the polytope 
    x = @variable(model, [1:m])
    z = G * x + c
    @constraint(model, x .>= -1.0)
    @constraint(model, x .<= 1.0)
    
    y = @variable(model, [1:n])
    @constraint(model, A*y .<= b)

    # Now, introduce a variable for our l-inf norm
    t = @variable(model, [1:n])
    @constraint(model, t .>= y - z)
    @constraint(model, t .>= z - y)
    @objective(model, Min, sum(t))

    optimize!(model)
    @assert termination_status(model) == OPTIMAL "Solve must result in optimal status"
    return sum(value.(t)) # should this add a TOL[] be here?
end

"""
    sign_custom(x)

    Our own sign function which is 1 when the input is 0 instead of 0 when the input is 0.
"""
sign_custom(x) = x >= 0.0 ? 1.0 : -1.0

"""
    farthest_points(h1::Hyperrectangle, h2::Hyperrectangle)

Find the farthest points
in a pair of hyperrectangles. This can be done by first finding the line segment connecting their centers. 
The sign of each coordinate of this line segment will tell us what direction to head in to get 
to the farthest vertex in each. We then take the p-norm between those two vertices. 

For elements of the center connecting line segment which are 0 (meaning that coordinate of the center is equal)
we arbitrarily set the direction to be 1.

TODO: this should work under any p norm >= 1, is that right?
"""
function farthest_points(h1::Hyperrectangle, h2::Hyperrectangle)
    center_line = center(h1) - center(h2)
    # If the center is equal in some dimension, choose the direction to be 1
    # TODO: double check that is legitimate for dimensions in which the center is 0. 
    direction = sign_custom.(center_line)
    point_one = center(h1) + direction .* radius_hyperrectangle(h1)
    point_two = center(h2) - direction .* radius_hyperrectangle(h2)
    return point_one, point_two
end

"""
    max_dist(h1::Hyperrectangle, h2::Hyperrectangle, p)

Find the maximum p-norm distance between two hyperrectangles. See farthest_points 
for a description of how the farthest points are found.
"""
function max_dist(h1::Hyperrectangle, h2::Hyperrectangle, p)
    @assert p >= 1.0 "p for p-norm must be greater than or equal to 1"
    point_one, point_two = farthest_points(h1, h2)
    return norm(point_one - point_two, p)
end

"""
   max_dist_l1(h1::Hyperrectangle, h2::Hyperrectangle)

A special case of the maximum distance between two hyperrectangles for the l-1 norm.
In this case, it should be equal to the l-1 norm of the center connecting line 
with the radii of each hyperrectangle added on. If you picture a 2-d case, the extra 
l-1 norm incurred from moving from the center point to the farthest vertex will be equal to 
moving half the width over and then half the height up or down. So, in the general case 
we add on the radius in each coordinate (which is equivalent to half the width and half the height in the 2-d case)
"""
function max_dist_l1(h1::Hyperrectangle, h2::Hyperrectangle)
    center_line = center(h1) - center(h2)
    return norm(center_line, 1) + sum(radius_hyperrectangle(h1)) + sum(radius_hyperrectangle(h2))
end
  

"""
    dist_polytope_point(A, b, point, p)

    A helper function which finds the distance for an arbitrary p-norm norm between a 
        polytope and a point. This is defined as 
    inf_x ||x - point||_p s.t. x in polytope
"""
function dist_polytope_point(A, b, point, p)
    x = Variable(size(A, 2))
    obj = norm(x - point, p)
    prob = minimize(obj, [A * x <= b])
    solve!(prob, Mosek.Optimizer(LOG=0))
    @assert prob.status == OPTIMAL "Solve must result in optimal status"
    return prob.optval
end

"""
    dist_polytope_point(A, b, point, p)

    A helper function which finds the distance for the l-inf norm between a 
        polytope and a point. It formulates this as an LP. This is defined as 
    inf_x ||x - point||_inf s.t. x in polytope
"""
function dist_polytope_point_linf(A, b, point; solver=Gurobi.Optimizer)
    model = Model(with_optimizer(solver, gurobi_env, OutputFlag=0))
    x = @variable(model, [1:size(A, 2)])
    @constraint(model, A * x .<= b)

    t = @variable(model)
    @constraint(model, t .>= x - point)
    @constraint(model, t .>= point - x)
    @objective(model, Min, t)
    optimize!(model)
    @assert termination_status(model) == OPTIMAL "Solve must result in optimal status"
    return value(t) # should this add a TOL[] be here?
end

"""
dist_polytope_point(A, b, point, p)

A helper function which finds the distance for the l-1 norm between a 
    polytope and a point. It formulates this as an LP. This is defined as 
inf_x ||x - point||_1 s.t. x in polytope
"""
function dist_polytope_point_l1(A, b, point; solver=Gurobi.Optimizer)
    model = Model(with_optimizer(solver, gurobi_env, OutputFlag=0))
    x = @variable(model, [1:size(A, 2)])
    @constraint(model, A * x .<= b)

    t = @variable(model, [1:size(A, 2)])
    @constraint(model, t .>= x - point)
    @constraint(model, t .>= point - x)
    @objective(model, Min, sum(t))
    optimize!(model)
    @assert termination_status(model) == OPTIMAL "Solve must result in optimal status"
    return sum(value.(t)) # should this add a TOL[] be here?
end


"""
    max_polytope_violation(zonotope::Zonotope, polytope)

Compute the maximum single violation of the linear constraints describing a polytope 
over a zonotope. Imagine the polytope is described by Ax <= b. We maximize a_i^T x - b for
x the zonotope where a_i is the ith row of A. By taking the maximum of this with 0, we get 
the possible violation of each constraint. If the max polytope violation is > 0, then some constraint 
can be violated, which means that the zonotope is not contained within the polytope. Otherwise, the 
zonotope is contained within the polytope since none of the polytope constraints can be violated. 
"""
function max_polytope_violation(zonotope::Zonotope, A, b)
    max_violation = -Inf
    for i = 1:size(A, 1)
        cur_violation = max(ρ(A[i, :], zonotope) - b[i], 0)
        if cur_violation > max_violation
            max_violation = cur_violation # update if need be
        end
    end
    return max_violation
end

"""
    max_polytope_violation(point::Vector{Float64}, A, b)

Compute the maximum violation of the constraints for a polytope described by Ax <= b. 
"""
max_polytope_violation(point::Vector{Float64}, A, b) = max(maximum(A * point - b), 0.0)

"""
    convex_program_over_zonotope(zonotope::Zonotope, convex_fcn, max)

Optimize a convex fcn over a zonotope. The convex fcn should map from a list of 
Convex variables the length of the dimension of the zonotope (equal to the height
 of its generator matrix) to a convex expression. 
"""
function convex_program_over_zonotope(zonotope::Zonotope, objective_fcn, max)
    G, c = zonotope.generators, zonotope.center 
    n, m = size(G) 
    x = Variable(m) # points in the hypercube defining the zonotope 
    obj = objective_fcn(G * x + c)
    prob = max ? maximize(obj, [x <= 1.0, x >= -1.0]) : minimize(obj, [x <= 1.0, x >= -1.0]) 
    solve!(prob, Mosek.Optimizer(LOG=0))
    @assert prob.status == OPTIMAL "Solve must result in optimal status"
    return prob.optval
end


"""
    get_acas_sets(property_number)

Get the input and output sets for acas under the standard definition of a problem 
    as trying to show x in X implies y in Y. This returns the input and output sets X, Y.
    Taken from https://github.com/NeuralNetworkVerification/Marabou/tree/master/resources/properties

"""
function get_acas_sets(property_number)
    if property_number == 1
        input_set = Hyperrectangle(low=[0.6, -0.5, -0.5, 0.45, -0.5], high=[0.6798577687, 0.5, 0.5, 0.5, -0.45])
        output_set = HalfSpace([1.0, 0.0, 0.0, 0.0, 0.0], 3.9911256459)
    elseif property_number == 2
        input_set = Hyperrectangle(low=[0.6, -0.5, -0.5, 0.45, -0.5], high=[0.6798577687, 0.5, 0.5, 0.5, -0.45])
        output_set = PolytopeComplement(HPolytope([-1.0 1.0 0.0 0.0 0.0; -1.0 0.0 1.0 0.0 0.0; -1.0 0.0 0.0 1.0 0.0; -1.0 0.0 0.0 0.0 1.0], [0.0; 0.0; 0.0; 0.0]))
    elseif property_number == 3
        input_set = Hyperrectangle(low=[-0.3035311561, -0.0095492966, 0.4933803236, 0.3, 0.3], high=[-0.2985528119, 0.0095492966, 0.5, 0.5, 0.5])
        output_set = PolytopeComplement(HPolytope([1.0 -1.0 0.0 0.0 0.0; 1.0 0.0 -1.0 0.0 0.0; 1.0 0.0 0.0 -1.0 0.0; 1.0 0.0 0.0 0.0 -1.0], [0.0; 0.0; 0.0; 0.0]))
    elseif property_number == 4
        input_set = Hyperrectangle(low=[-0.3035311561, -0.0095492966, 0.0, 0.3181818182, 0.0833333333], high=[-0.2985528119, 0.0095492966, 0.0, 0.5, 0.1666666667])
        output_set = PolytopeComplement(HPolytope([1.0 -1.0 0.0 0.0 0.0; 1.0 0.0 -1.0 0.0 0.0; 1.0 0.0 0.0 -1.0 0.0; 1.0 0.0 0.0 0.0 -1.0], [0.0; 0.0; 0.0; 0.0]))
    else
        @assert false "Unsupported property number"
    end 

    return input_set, output_set
end