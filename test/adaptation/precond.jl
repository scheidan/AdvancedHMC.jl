using Test, LinearAlgebra, Distributions, AdvancedHMC, Random
using AdvancedHMC.Adaptation: WelfordVar, NaiveVar, WelfordCov, NaiveCov, add_sample!, get_var, get_cov, reset!
using DiffResults: GradientResult, value, gradient
using ForwardDiff: gradient!

# Check that the estimated variance is approximately correct.
@testset "Online v.s. naive v.s. true var/cov estimation" begin
    D = 10
    T = Float64
    sz = (D,)
    n_samples = 100_000

    var_welford = WelfordVar(T, sz)
    var_naive = NaiveVar(T, sz)
    var_estimators = [var_welford, var_naive]
    cov_welford = WelfordCov(T, sz)
    cov_naive = NaiveCov(T, sz)
    cov_estimators = [cov_welford, cov_naive]
    estimators = [var_estimators..., cov_estimators...]

    for dist in [MvNormal(zeros(D), ones(D)), Dirichlet(D, 1)]
        for _ = 1:n_samples
            s = rand(dist)
            for estimator in estimators
                add_sample!(estimator, s)
            end
        end

        @test get_var(var_welford) ≈ get_var(var_naive) atol=0.1D
        for estimator in var_estimators
            @test get_var(estimator) ≈ var(dist) atol=0.1D
        end

        @test get_cov(cov_welford) ≈ get_cov(cov_naive) atol=0.1D^2
        for estimator in cov_estimators
            @test get_cov(estimator) ≈ cov(dist) atol=0.1D^2
        end

        for estimator in estimators
            reset!(estimator)
        end
    end
end

@testset "Preconditioner constructors" begin
    θ = [0.0, 0.0, 0.0, 0.0]
    pc1 = Preconditioner(UnitEuclideanMetric) # default dim = 2
    pc2 = Preconditioner(DiagEuclideanMetric)
    pc3 = Preconditioner(DenseEuclideanMetric)

    # Var adaptor dimention should be increased to length(θ) from 2
    AdvancedHMC.adapt!(pc1, θ, 1.)
    AdvancedHMC.adapt!(pc2, θ, 1.)
    AdvancedHMC.adapt!(pc3, θ, 1.)
    @test AdvancedHMC.Adaptation.getM⁻¹(pc2) == ones(length(θ))
    @test AdvancedHMC.Adaptation.getM⁻¹(pc3) == LinearAlgebra.diagm(0 => ones(length(θ)))
end

@testset "Stan HMC adaptors" begin
    θ = [0.0, 0.0, 0.0, 0.0]

    adaptor1 = StanHMCAdaptor(
        Preconditioner(UnitEuclideanMetric),
        NesterovDualAveraging(0.8, 0.5)
    )
    adaptor2 = StanHMCAdaptor(
        Preconditioner(DiagEuclideanMetric),
        NesterovDualAveraging(0.8, 0.5)
    )
    adaptor3 = StanHMCAdaptor(
        Preconditioner(DenseEuclideanMetric),
        NesterovDualAveraging(0.8, 0.5)
    )
    for a in [adaptor1, adaptor2, adaptor3]
        AdvancedHMC.initialize!(a, 1_000)
        @test a.state.window_start == 76
        @test a.state.window_end == 950
        @test a.state.window_splits == [100, 150, 250, 450, 950]
        AdvancedHMC.adapt!(a, θ, 1.)
    end
    @test AdvancedHMC.Adaptation.getM⁻¹(adaptor2) == ones(length(θ))
    @test AdvancedHMC.Adaptation.getM⁻¹(adaptor3) == LinearAlgebra.diagm(0 => ones(length(θ)))

    @test_deprecated StanHMCAdaptor(
        1_000,
        Preconditioner(DiagEuclideanMetric),
        NesterovDualAveraging(0.8, 0.5)
    )
end

let D=10
    function buildfuncs(target)
        ℓπ(θ) = logpdf(target, θ)

        function ∂ℓπ∂θ(θ)
            res = GradientResult(θ)
            gradient!(res, ℓπ, θ)
            return (value(res), gradient(res))
        end

        return ℓπ, ∂ℓπ∂θ
    end

    function runnuts(ℓπ, ∂ℓπ∂θ, metric; n_samples=2_000)
        n_adapts = 1_000

        θ_init = rand(D)

        h = Hamiltonian(metric, ℓπ, ∂ℓπ∂θ)
        prop = NUTS(Leapfrog(find_good_eps(h, θ_init)))
        adaptor = StanHMCAdaptor(
            Preconditioner(metric),
            NesterovDualAveraging(0.8, prop.integrator)
        )
        samples, stats = sample(h, prop, θ_init, n_samples, adaptor, n_adapts; verbose=false)
        return (samples=samples, stats=stats, adaptor=adaptor)
    end

    @testset "Adapted mass v.s. true variance" begin
        n_tests = 5

        @testset "DiagEuclideanMetric" begin
            for _ in 1:n_tests
                Random.seed!(1)

                # Random variance
                σ = ones(D) + abs.(randn(D))

                # Diagonal Gaussian
                target = MvNormal(zeros(D), σ)
                ℓπ, ∂ℓπ∂θ = buildfuncs(target)

                res = runnuts(ℓπ, ∂ℓπ∂θ, DiagEuclideanMetric(D))
                @test res.adaptor.pc.var ≈ σ .^ 2 rtol=0.2

                res = runnuts(ℓπ, ∂ℓπ∂θ, DenseEuclideanMetric(D))
                @test res.adaptor.pc.covar ≈ diagm(0 => σ .^ 2) rtol=0.25
            end
        end

        @testset "DenseEuclideanMetric" begin
            for _ in 1:n_tests
                # Random covariance
                m = randn(D, D)
                Σ = m' * m

                # Correlated Gaussian
                target = MvNormal(zeros(D), Σ)
                ℓπ, ∂ℓπ∂θ = buildfuncs(target)

                res = runnuts(ℓπ, ∂ℓπ∂θ, DiagEuclideanMetric(D))
                @test res.adaptor.pc.var ≈ diag(Σ) rtol=0.2

                res = runnuts(ℓπ, ∂ℓπ∂θ, DenseEuclideanMetric(D))
                @test res.adaptor.pc.covar ≈ Σ rtol=0.25
            end
        end

    end

    @testset "Initialisation adaptor by metric" begin
        target = MvNormal(zeros(D), 1)
        ℓπ, ∂ℓπ∂θ = buildfuncs(target)

        mass_init = fill(0.5, D)
        res = runnuts(ℓπ, ∂ℓπ∂θ, DiagEuclideanMetric(mass_init); n_samples=1)
        @test res.adaptor.pc.var == mass_init

        mass_init = diagm(0 => fill(0.5, D))
        res = runnuts(ℓπ, ∂ℓπ∂θ, DenseEuclideanMetric(mass_init); n_samples=1)
        @test res.adaptor.pc.covar == mass_init
    end
end

@testset "rand momentum variables from metric via vector of RNGs" begin
    D = 10
    n_chains = 5
    rng = [MersenneTwister(1) for _ in 1:n_chains]
    for metric in [
        UnitEuclideanMetric((D, n_chains)),
        DiagEuclideanMetric((D, n_chains)),
        # DenseEuclideanMetric((D, n_chains)) # not supported at the moment
    ]
        r = rand(rng, metric)
        all_same = true
        for i in 2:n_chains
            all_same = all_same && r[:,i] == r[:,1]
        end
        @test all_same
    end
end