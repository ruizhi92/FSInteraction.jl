"""
    SaddleSystem2d((ċ,f,u̇,λ), (A⁻¹,B₁ᵀ,B₂), (M,G₁ᵀ,G₂), (T₁ᵀ,T₂); [tol=1e-3])

Construct the computational operators for a saddle-point system of the form
\$[A B₁ᵀ -B₁ᵀT₂Mf 0; B₂ 0 -T₂  0; 0 -T₁ᵀ M G₁ᵀ; 0 0 G₂ 0][ċ; f; u̇; λ]\$. Note that
this saddle system is a little different from the 1d body form. Also note that
the constituent operators are passed in as a tuple in the order seen here.
Each of these operators could act on its corresponding data type in a function-like
way, e.g. `A⁻¹(u)`, or in a matrix-like way, e.g., `A⁻¹*u`.

The optional argument `tol` sets the tolerance for iterative solution (if
  applicable). Its default is 1e-3.

# Arguments

- `ċ` : change of fluid vorticity in Node form
- `f` : constraint fluid force in VectorData form
- `u̇` : change of joint velocity
- `λ` : constraint joint force
- `A⁻¹` : operator evaluating the inverse of `A` on data of type `ċ`, return type `ċ`,
            here represents the diffusion operator
- `B₁ᵀ` : operator evaluating the influence of fluid constraint force on fluid state,
            acting on `f` and returning type `ċ`
- `B₂` : operator evaluating the influence of fluid state on fluid constraints,
            acting on `ċ` and returning type `f`
- `M` : operator evaluating the body chain inertia matrix
- `G₁ᵀ` : a matrix evaluating the influence of joint constraint force on body state,
            acting on `λ` and returning type `u̇`
- `G₂` : a matrix evaluating the influence of body state on joint constraints,
            acting on `u̇` and returning type `λ`
- `T₁ᵀ` : operator evaluating the influence of fluid constraint force on body state,
            acting on `f` and returning type `u̇`
- `T₂` : operator evaluating the influence of body state on fluid constraints,
            acting on `u̇` and returning type `f`
"""
struct SaddleSystem2d{TC,TF,TU,Tλ,FAB,FT1,FT2,FSF,Nf,Nλ}

    # basic operators needed
    A⁻¹B₁ᵀ :: FAB
    A⁻¹B₁ᵀf :: TC
    Mf :: Matrix{Float64}
    T₁ᵀ :: FT1
    T₂ :: FT2

    # fluid and body Schur complement
    Sf :: FSF   # B₂Hᵢ₋₁,ᵢB₁ᵀ
    Sf⁻¹mat :: Matrix{Float64}
    Sbmat :: Matrix{Float64}   # G₂M⁻¹G₁ᵀ

    # scratch space
    fbuffer_1 :: TF
    fbuffer_2 :: TF
    u̇buffer :: TU
    tmpvec :: Vector{Float64}
    tol :: Float64
end

function (::Type{SaddleSystem2d})(state::Tuple{TC,TF,TU,Tλ},
                                fluidop::Tuple{FA,FB1,FB2},
                                bodyop::Tuple{FM,FG1,FG2},
                                fsiop::Tuple{FT1,FT2};
                                tol::Float64=1e-3,
                                ρb::Float64=1.0,
                                Mf::Matrix{Float64}=1.0/ρb*bodyop[1]) where {TC,TF,TU,Tλ,FA,FB1,FB2,FM,FG1,FG2,FT1,FT2}
    ċ, f, u̇, λ = state

    A⁻¹, B₁ᵀ, B₂ = fluidop
    M, G₁ᵀ, G₂ = bodyop
    T₁ᵀ, T₂ = fsiop

    # check for fluid methods
    fsys = (A⁻¹, B₁ᵀ, B₂)
    foptypes = (TC,TF,TC)
    fopnames = ("A⁻¹","B₁ᵀ","B₂")
    fops = []

    for (i,typ) in enumerate(foptypes)
      if hasmethod(fsys[i],Tuple{typ})
        push!(fops,fsys[i])
    elseif hasmethod(*,Tuple{typeof(fsys[i]),typ})
        push!(fops,x->fsys[i]*x)
      else
        error("No valid operator for $(fopnames[i]) supplied")
      end
    end
    A⁻¹, B₁ᵀ, B₂ = fops

    # sractch space
    ċbuffer = deepcopy(ċ)
    fbuffer_1 = deepcopy(f)
    fbuffer_2 = deepcopy(f)
    u̇buffer = deepcopy(u̇)
    λbuffer = deepcopy(λ)
    Nf = length(f)
    Nu̇ = length(u̇)
    Nλ = length(λ)
    tmpvec = zeros(Nu̇+Nλ)

    # fluid saddlesystem using ViscousFlow.SaddleSystem
    Sf = Sad.SaddleSystem((ċ,f),(A⁻¹,B₁ᵀ,B₂),tol=tol,
                issymmetric=false,isposdef=true,store=true,precompile=true)
    Sf⁻¹mat = -inv(Sf.S⁻¹)

    # store rigid body saddlesystem in matrix
    Sbmat = zeros(Nu̇+Nλ,Nu̇+Nλ)
    Stmpmat = zeros(Nu̇,Nu̇)

    # T₁ᵀSf⁻¹T₂
    T₁ᵀSf⁻¹T₂(u̇) = T₁ᵀ(Sf⁻¹mat*T₂(u̇))
    Stmp = LinearMap(T₁ᵀSf⁻¹T₂,Nu̇;ismutating=false,issymmetric=false,isposdef=true)
    ubuffer_tmp1 = zeros(Nu̇)
    ubuffer_tmp2 = zeros(Nu̇)
    for i = 1:Nu̇
      ubuffer_tmp1[i] = 1.0
      ubuffer_tmp2 .= Stmp*ubuffer_tmp1
      Stmpmat[:,i] .= ubuffer_tmp2
      ubuffer_tmp1[i] = 0.0
    end

    # M-Mf
    Sbmat[1:Nu̇,1:Nu̇] .= Stmpmat
    if ρb != 0.0
        Sbmat[1:Nu̇,1:Nu̇] .+= (1-1.0/ρb)*M
    else
        Sbmat[1:Nu̇,1:Nu̇] .-= Mf
    end
    Sbmat[1:Nu̇,Nu̇+1:end] .= G₁ᵀ
    Sbmat[Nu̇+1:end,1:Nu̇] .= G₂

    # functions for correction step
    A⁻¹B₁ᵀ(f::TF) = (A⁻¹∘B₁ᵀ)(f)

    saddlesys2d = SaddleSystem2d{TC,TF,TU,Tλ,typeof(A⁻¹B₁ᵀ),typeof(T₁ᵀ),typeof(T₂),typeof(Sf),Nf,Nλ}(
                                A⁻¹B₁ᵀ,ċbuffer,Mf,T₁ᵀ,T₂,Sf,Sf⁻¹mat,Sbmat,fbuffer_1,fbuffer_2,u̇buffer,tmpvec,tol)

    return saddlesys2d
end


function Base.show(io::IO, S::SaddleSystem2d{TC,TF,TU,Tλ,FAB,FT1,FT2,FSF,Nf,Nλ}) where {TC,TF,TU,Tλ,FAB,FT1,FT2,FSF,Nf,Nλ}
    println(io, "Saddle system with $Nf constraints on fluid and $Nλ constraints on 2d body")
    println(io, "   Fluid state of type $TC")
    println(io, "   Fluid force of type $TF")
    println(io, "   Body state of type $TU")
    println(io, "   Joint force of type $Tλ")
end

function ldiv!(state::Tuple{TC,TF,TU,Tλ},
                sys::TSYS,
                rhs::Tuple{TC,TF,TU,Tλ}) where {TC,TF,TU,Tλ,TSYS<:SaddleSystem2d}

    # retrive states and rhs
    rċ, rf, ru̇, rλ = rhs
    ċ, f, u̇, λ = state

    # solve for fluid with "stationary " body only
    ċ, f = sys.Sf\(rċ, rf)

    # solve for body with fluid added mass
    sys.u̇buffer .= sys.T₁ᵀ(f)
    ru̇ .+= sys.u̇buffer
    sys.tmpvec .= [ru̇;rλ]
    sys.tmpvec .= sys.Sbmat\sys.tmpvec
    Nu̇ = length(u̇)
    u̇ .= sys.tmpvec[1:Nu̇]
    λ .= sys.tmpvec[Nu̇+1:end]

    # store for later use
    sys.fbuffer_1 .= sys.T₂(u̇)
    sys.fbuffer_1 .= sys.Sf⁻¹mat*sys.fbuffer_1

    # correct fluid state and force with moving body effect
    sys.A⁻¹B₁ᵀf .= sys.A⁻¹B₁ᵀ(sys.fbuffer_1)
    ċ .+= sys.A⁻¹B₁ᵀf
    f .-= sys.fbuffer_1

    state = ċ, f, u̇, λ
end


\(sys::TSYS,rhs::Tuple{TC,TF,TU,Tλ}) where {TC,TF,TU,Tλ,TSYS<:SaddleSystem2d} =
    ldiv!(deepcopy.(rhs),sys,rhs)
