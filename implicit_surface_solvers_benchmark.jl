using Oceananigans
using Oceananigans.Units
using Oceananigans.ImmersedBoundaries: ImmersedBoundaryGrid, GridFittedBottom
using Printf

architecture = CPU()

underlying_grid = RectilinearGrid(architecture,
                                  topology = (Periodic, Bounded, Bounded), 
                                  size = (64, 64, 24),
                                  x = (-500kilometers, 500kilometers),
                                  y = (-500kilometers, 500kilometers),
                                  z = (-1kilometers, 0),
                                  halo = (4, 4, 4))

const Lz = underlying_grid.Lz
const width = 50kilometers
bump(x, y) = - Lz * (1 - 0.2 * exp(-(x^2 + y^2) / 2width^2))
grid = ImmersedBoundaryGrid(underlying_grid, GridFittedBottom(bump))

# Physics
Δx, Δz = grid.Lx / grid.Nx, grid.Lz / grid.Nz
𝒜 = Δz/Δx # Grid cell aspect ratio.

κh = 0.1    # [m² s⁻¹] horizontal diffusivity
νh = 0.1    # [m² s⁻¹] horizontal viscosity
κz = 𝒜 * κh # [m² s⁻¹] vertical diffusivity
νz = 𝒜 * νh # [m² s⁻¹] vertical viscosity

horizontal_closure = HorizontalScalarDiffusivity(ν = νh, κ = κh)

diffusive_closure = VerticalScalarDiffusivity(VerticallyImplicitTimeDiscretization();
                                              ν = νz, κ = κz)

model = HydrostaticFreeSurfaceModel(; grid,
                                    free_surface = ImplicitFreeSurface(solver_method = :PreconditionedConjugateGradient),
                                    coriolis = BetaPlane(latitude = -45),
                                    buoyancy = BuoyancyTracer(),
                                    closure = (diffusive_closure, horizontal_closure),
                                    tracers = :b,
                                    momentum_advection = WENO(),
                                    tracer_advection = WENO())

# Initial condition: a baroclinically unstable situation!
ramp(y, δy) = min(max(0, y/δy + 1/2), 1)

# Parameters
N² = 4e-6 # [s⁻²] buoyancy frequency / stratification
M² = 8e-8 # [s⁻²] horizontal buoyancy gradient

δy = 50kilometers
δb = δy * M²
ϵb = 1e-2 * δb # noise amplitude

bᵢ(x, y, z) = N² * z + δb * ramp(y, δy) + ϵb * randn()

set!(model, b=bᵢ)

Δt = 10minutes
simulation = Simulation(model; Δt, stop_time=2days)

wall_clock = Ref(time_ns())

function print_progress(sim)

    elapsed = 1e-9 * (time_ns() - wall_clock[])

    msg = @sprintf("Iter: %d, time: %s, wall time: %s, max|w|: %6.3e, m s⁻¹, next Δt: %s\n",
                iteration(sim), prettytime(sim), prettytime(elapsed),
                maximum(abs, sim.model.velocities.w), prettytime(sim.Δt))

    wall_clock[] = time_ns()

    try
        solver_iterations = sim.model.free_surface.implicit_step_solver.preconditioned_conjugate_gradient_solver.iteration
        msg *= @sprintf("solver iterations: %d", solver_iterations)
    catch
    end

    @info msg

    return nothing
end

simulation.callbacks[:print_progress] = Callback(print_progress, IterationInterval(10))

@info "Running simulation:"

run!(simulation)
