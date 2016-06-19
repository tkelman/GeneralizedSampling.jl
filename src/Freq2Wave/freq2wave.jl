# ------------------------------------------------------------
# 1D change of basis matrix

function Freq2Wave(samples::DenseVector, wavename::AbstractString, J::Int, B::Float64=NaN; args...)
	vm = van_moment(wavename)
	Nint = 2^J
	Nint >= 2*vm-1 || throw(AssertionError("Scale it not large enough for this wavelet"))
	
	# TODO: Good condition?
	M = length(samples)
	if Nint >= M
		warn("The scale is high compared to the number of samples")
	end

	# Weights for non-uniform samples
	if isuniform(samples)
		W = Nullable{ Vector{Complex{Float64}} }()
	else
		isnan(B) && error("Samples are not uniform; supply bandwidth")
		Nint <= 2*B || warn("The scale is high compared to the bandwidth")
		W = sqrt(weights(samples, B))
		W = Nullable(complex( W ))
	end

	# Fourier transform of the internal scaling function
	internal = FourScalingFunc( samples, wavename, J; args... )

	# Diagonal matrix used in 'multiplication' with NFFT
	diag = Vector{Complex{Float64}}(M)
	for m in 1:M
		diag[m] = internal[m] * cis(-pi*samples[m])
	end

	# The number of internal wavelets in reconstruction
	if hasboundary(wavename)
		Nint -= 2*van_moment(wavename)
		Nint <= 0 && error("Too few wavelets: Boundary functions overlap")
	end

	# NFFTPlans: Frequencies must be in the torus [-1/2, 1/2)
	# TODO: Should window width m and oversampling factor sigma be changed for higher precision?
	xi = samples*2.0^(-J)
	frac!(xi)
	p = NFFTPlan(xi, Nint)

	# Wavelets w/o boundary
	if !hasboundary(wavename)
		return Freq2NoBoundaryWave1D(internal, W, J, wavename, diag, p)
	else
		left = FourScalingFunc( samples, wavename, 'L', J; args... )
		right = FourScalingFunc( samples, wavename, 'R', J; args... )

		return Freq2BoundaryWave1D(internal, W, J, wavename, diag, p, left, right)
	end
end

@doc """
	isuniform(Freq2Wave)

Is the change of basis matrix based on uniform samples.
"""->
function isuniform(T::Freq2Wave)
	isnull(T.weights)
end

@doc """
	hasboundary(T::Freq2Wave) -> Bool

Does the wavelet in the change of basis matrix `T` have boundary correction.
"""->
function hasboundary(T::Freq2Wave)
	isdefined(T, :left)
end


# ------------------------------------------------------------
# Basic operations for 1D Freq2Wave

function Base.collect(T::Freq2NoBoundaryWave1D)
	M, N = size(T)

	F = Array{Complex{Float64}}(M, N)
	for n = 0:N-1
		for m = 1:M
			@inbounds F[m,n+1] = T.internal[m]*cis( -twoπ*n*T.NFFT.x[m] )
		end
	end

	if !isuniform(T)
		broadcast!(*, F, F, get(T.weights))
	end

	return F
end

function Base.collect(T::Freq2BoundaryWave1D)
	M, N = size(T)
	F = Array{Complex{Float64}}(M, N)

	p = van_moment(T)

	# Left boundary
	F[:,1:p] = T.left

	# Internal function
	for n in p:N-p-1
		for m in 1:M
			@inbounds F[m,n+1] = T.internal[m]*cis( -twoπ*n*T.NFFT.x[m] )
		end
	end

	# Right boundary
	F[:,N-p+1:N] = T.right

	if !isuniform(T)
		broadcast!(*, F, F, get(T.weights))
	end

	return F
end


# ------------------------------------------------------------
# 2D change of basis matrix

@doc """
	dim(Freq2wave)

Return the dimension of the `T`.
"""->
dim(::Freq2Wave1D) = 1
dim(::Freq2Wave2D) = 2

@doc """
	wscale(Freq2Wave)

Return the scale of the wavelet coefficients.
"""->
function wscale(T::Freq2Wave)
	T.J
end

@doc """
	wsize(T::Freq2Wave)

The size of the reconstructed wavelet coefficients.

- When `D` == 1, the output is (Int,)
- When `D` == 2, the output is (Int,Int)
"""->
function wsize(T::Freq2BoundaryWave2D)
	N = 2^wscale(T)
	return (N, N)
end
wsize(T::Freq2NoBoundaryWave1D) = T.NFFT.N
wsize(T::Freq2BoundaryWave1D) = (2^wscale(T),)
wsize(T::Freq2NoBoundaryWave2D) = T.NFFT.N

function Freq2Wave(samples::DenseMatrix, wavename::AbstractString, J::Int, B::Float64=NaN; args...)
	vm = van_moment(wavename)
	Nint = 2^J
	Nint >= 2*vm-1 || throw(AssertionError("Scale it not large enough for this wavelet"))
	# TODO: 2 columns *or* 2 rows
	M = size(samples, 1)
	size(samples,2) == 2 || throw(DimensionMismatch("Samples must have two columns"))

	# TODO: Good condition?
	if Nint >= M
		warn("The scale is high compared to the number of samples")
	end

	# Weights for non-uniform samples
	if isuniform(samples)
		W = Nullable{ Vector{Complex{Float64}} }()
	else
		isnan(B) && error("Samples are not uniform; supply bandwidth")
		Nint <= 2*B || warn("The scale is high compared to the bandwidth")
		W = sqrt(weights(samples, B))
		W = Nullable(complex( W ))
	end

	# Fourier transform of the internal scaling function
	internal = FourScalingFunc( samples, wavename, J )

	# Diagonal matrix for multiplication with internal scaling function
	xi = samples'
	diag = internal.'
	for m in 1:M, d in 1:2
		diag[d,m] *= cis( -pi*xi[d,m] )
	end

	# The number of internal wavelets in reconstruction
	if hasboundary(wavename)
		Nint -= 2*van_moment(wavename)
		Nint <= 0 && error("Too few wavelets: Boundary functions overlap")
	end

	# NFFTPlans: Frequencies must be in the torus [-1/2, 1/2)^2
	scale!(xi, 2.0^(-J))
	frac!(xi)
	p = NFFTPlan(xi, (Nint,Nint))

	# Wavelets w/o boundary
	if !hasboundary(wavename)
		return Freq2NoBoundaryWave2D(internal, W, J, wavename, diag, p)
	else
		samplesx = slice(samples, :, 1)
		samplesy = slice(samples, :, 2)

		left = cell(2,vm+1)
		left[1] = FourScalingFunc( samplesx, wavename, 'L', J; args... )
		left[2] = FourScalingFunc( samplesy, wavename, 'L', J; args... )

		right = cell(2,vm+1)
		right[1] = FourScalingFunc( samplesx, wavename, 'R', J; args... )
		right[2] = FourScalingFunc( samplesy, wavename, 'R', J; args... )

		# Views of the columns in left/right
		for k in 1:vm, d in 1:2
			left[d,k+1]  = slice( left[d], :, k )
			right[d,k+1] = slice( right[d], :, k )
		end

		return Freq2BoundaryWave2D(internal, W, J, wavename, diag, p, left, right)
	end
end

@doc """
	left(T, d, k) -> Vector

Return (a view of) the `k`'th column of `T`'s left boundary Fourier
transform in dimension `d`.
For the x coordinate `d = 1` and for the y coordinate `d = 2`.
"""->
left(T::Freq2BoundaryWave2D, d::Integer, k::Integer) = T.left[d,k+1]
left(T::Freq2BoundaryWave2D, d::Integer) = T.left[d,1]
@doc """
	right(T, d, k) -> Vector

Return (a view of) the `k`'th column of `T`'s right boundary Fourier
transform in dimension `d`.
For the x coordinate `d = 1` and for the y coordinate `d = 2`.

Note that `right(T, d, 1)` is the right boundary functions *furthest*
from the boundary, cf. the ordering from `FourScalingFunc`.
"""->
right(T::Freq2BoundaryWave2D, d::Integer, k::Integer) = T.right[d,k+1]
right(T::Freq2BoundaryWave2D, d::Integer) = T.right[d,1]

function Base.A_mul_B!(y::DenseVector{Complex{Float64}}, T::Freq2NoBoundaryWave1D, x::DenseVector{Complex{Float64}})
	size(T,1) == length(y) || throw(DimensionMismatch())
	size(T,2) == length(x) || throw(DimensionMismatch())

	NFFT.nfft!(T.NFFT, x, y)
	had!(y, T.diag)

	isuniform(T) || had!(y, get(T.weights))

	return y
end

function Base.A_mul_B!(y::DenseVector{Complex{Float64}}, T::Freq2NoBoundaryWave2D, X::DenseMatrix{Complex{Float64}})
	(M = size(T,1)) == length(y) || throw(DimensionMismatch())
	wsize(T) == size(X) || throw(DimensionMismatch())

	NFFT.nfft!(T.NFFT, X, y)
	for m in 1:M, d in 1:2
		@inbounds y[m] *= T.diag[d,m]
	end

	isuniform(T) || had!(y, get(T.weights))

	return y
end


function Base.A_mul_B!(y::DenseVector{Complex{Float64}}, T::Freq2BoundaryWave1D, x::DenseVector{Complex{Float64}})
	(M = size(T,1)) == length(y) || throw(DimensionMismatch())
	size(T,2) == length(x) || throw(DimensionMismatch())

	xleft, xint, xright = split(x, van_moment(T))

	# Internal scaling function
	NFFT.nfft!(T.NFFT, xint, y)
	had!(y, T.diag)

	# Contribution from the boundaries
	BLAS.gemv!('N', ComplexOne, T.left, xleft, ComplexOne, y)
	BLAS.gemv!('N', ComplexOne, T.right, xright, ComplexOne, y)

	isuniform(T) || had!(y, get(T.weights))

	return y
end

function Base.A_mul_B!(y::StridedVector{Complex{Float64}}, T::Freq2BoundaryWave2D, X::DenseMatrix{Complex{Float64}}, d::Integer, k::Integer)
	p = van_moment(T)
	N = size(X,1)
	xint = slice(X, p+1:N-p, k)

	# Internal scaling function
	if d == 1
		NFFT.nfft!(T.NFFTx, xint, y)
	elseif d == 2
		NFFT.nfft!(T.NFFTy, xint, y)
	else
		throw(DimensionMismatch())
	end
	for m in 1:length(y)
		@inbounds y[m] *= T.diag[d,m]
	end

	# Contribution from the boundaries
	xleft = slice(X, 1:p, k)
	BLAS.gemv!('N', ComplexOne, T.left[d], xleft, ComplexOne, y)
	xright = slice(X, N-p+1:N, k)
	BLAS.gemv!('N', ComplexOne, T.right[d], xright, ComplexOne, y)

	isuniform(T) || had!(y, get(T.weights))

	return y
end

function Base.A_mul_B!(y::DenseVector{Complex{Float64}}, T::Freq2BoundaryWave2D, X::DenseMatrix{Complex{Float64}})
	(M = size(T,1)) == length(y) || throw(DimensionMismatch())
	(N = wsize(T)) == size(X) || throw(DimensionMismatch())
	
	vm = van_moment(T)
	# TODO: Skip split
	S = split(X, vm)

	# Internal scaling functions
	NFFT.nfft!(T.NFFT, S.internal, y)
	for m in 1:M, d in 1:2
		@inbounds y[m] *= T.diag[d,m]
	end

	# Update y with border contributions
	for k in 1:vm
		# Left
		A_mul_B!( T.tmpMulVec, T, X, 1, k )
		yphad!(y, left(T,2,k), T.tmpMulVec)

		# Right
		A_mul_B!( T.tmpMulVec, T, X, 1, N[2]-vm+k )
		yphad!(y, right(T,2,k), T.tmpMulVec)

		# Upper
		x = slice(X, k, vm+1:N[2]-vm)
		NFFT.nfft!( T.NFFTy, x, T.tmpMulVec )
		for m in 1:M
			@inbounds T.tmpMulVec[m] *= T.diag[2,m]
		end
		yphad!(y, left(T,1,k), T.tmpMulVec)

		# Lower
		x = slice(X, N[1]-vm+k, vm+1:N[2]-vm)
		NFFT.nfft!( T.NFFTy, x, T.tmpMulVec )
		for m in 1:M
			@inbounds T.tmpMulVec[m] *= T.diag[2,m]
		end
		yphad!(y, right(T,1,k), T.tmpMulVec)
	end

	isuniform(T) || had!(y, get(T.weights))

	return y
end

function Base.A_mul_B!(y::DenseVector{Complex{Float64}}, T::Freq2Wave2D, x::DenseVector{Complex{Float64}})
	size(T,2) == length(x) || throw(DimensionMismatch())

	X = reshape(x, wsize(T))
	A_mul_B!(y, T, X)

	return y
end

function Base.(:(*))(T::Freq2Wave, x::DenseArray)
	if !isa(x, Array{Complex{Float64}})
		x = map(Complex{Float64}, x)
	end

	y = Array{Complex{Float64}}( size(T,1) )
	A_mul_B!(y, T, x)

	return y
end


function Base.Ac_mul_B!(z::DenseVector{Complex{Float64}}, T::Freq2NoBoundaryWave1D, v::DenseVector{Complex{Float64}})
	(M = size(T,1)) == length(v) || throw(DimensionMismatch())
	size(T,2) == length(z) || throw(DimensionMismatch())

	for m in 1:M
		@inbounds T.tmpMulVec[m] = conj(T.diag[m]) * v[m]
	end
	isuniform(T) || had!(T.tmpMulVec, get(T.weights))

	NFFT.nfft_adjoint!(T.NFFT, T.tmpMulVec, z)

	return z
end

function Base.Ac_mul_B!(Z::DenseMatrix{Complex{Float64}}, T::Freq2NoBoundaryWave2D, v::DenseVector{Complex{Float64}})
	(M = size(T,1)) == length(v) || throw(DimensionMismatch())
	wsize(T) == size(Z) || throw(DimensionMismatch())

	for m in 1:M
		@inbounds T.tmpMulVec[m] = v[m]
		for d in 1:2
			@inbounds T.tmpMulVec[m] *= conj(T.diag[d,m])
		end
	end
	isuniform(T) || had!(T.tmpMulVec, get(T.weights))

	NFFT.nfft_adjoint!(T.NFFT, T.tmpMulVec, Z)

	return Z
end

function Base.Ac_mul_B!(z::DenseVector{Complex{Float64}}, T::Freq2BoundaryWave1D, v::DenseVector{Complex{Float64}})
	(M = size(T,1)) == length(v) || throw(DimensionMismatch())
	size(T,2) == length(z) || throw(DimensionMismatch())

	zleft, zint, zright = split(z, van_moment(T))

	# Boundary contributions are first as they don't use T.diag
	copy!(T.tmpMulVec, v)
	isuniform(T) || had!(T.tmpMulVec, get(T.weights))
	Ac_mul_B!( zleft, T.left, T.tmpMulVec )
	Ac_mul_B!( zright, T.right, T.tmpMulVec )

	# Internal scaling function
	hadc!(T.tmpMulVec, T.diag)
	NFFT.nfft_adjoint!(T.NFFT, T.tmpMulVec, zint)

	return z
end

# Ac_mul_B! for the `k`'th column of `Z` using the `d`'th dimension of T
function Base.Ac_mul_B!(Z::StridedMatrix{Complex{Float64}}, T::Freq2BoundaryWave2D, v::DenseVector{Complex{Float64}}, d::Integer, k::Integer)
	#= (M = size(T,1)) == length(v) || throw(DimensionMismatch()) =#
	#= wsize(T) == size(Z) || throw(DimensionMismatch()) =#

	copy!(T.tmpMulVec, v)
	isuniform(T) || had!(T.tmpMulVec, get(T.weights))

	vm = van_moment(T)
	N = size(Z,1)

	zleft = slice(Z, 1:vm, k)
	Ac_mul_B!( zleft, left(T,d), T.tmpMulVec )
	zright = slice(Z, N-vm+1:N, k)
	Ac_mul_B!( zright, right(T,d), T.tmpMulVec )

	# Internal scaling function
	for m in 1:length(v)
		@inbounds T.tmpMulVec[m] *= conj(T.diag[d,m])
	end

	zint = slice(Z, vm+1:N-vm, k)
	if d == 1
		NFFT.nfft_adjoint!(T.NFFTx, T.tmpMulVec, zint)
	elseif d == 2
		NFFT.nfft_adjoint!(T.NFFTy, T.tmpMulVec, zint)
	else
		throw(DimensionMismatch())
	end

	return Z
end

function Base.Ac_mul_B!(Z::DenseMatrix{Complex{Float64}}, T::Freq2BoundaryWave2D, v::DenseVector{Complex{Float64}})
	(M = size(T,1)) == length(v) || throw(DimensionMismatch())
	(N = wsize(T)) == size(Z) || throw(DimensionMismatch())
	
	# As in Ac_mul_B! for Freq2BoundaryWave1D
	copy!(T.weigthedVec, v)
	isuniform(T) || had!(T.weigthedVec, get(T.weights))

	vm = van_moment(T)
	S = split(Z, vm)

	# Update borders
	for k in 1:vm
		# Left
		hadc!(T.tmpMulcVec, T.weigthedVec, left(T,2,k))
		Ac_mul_B!( Z, T, T.tmpMulcVec, 1, k )

		# Right
		hadc!(T.tmpMulcVec, T.weigthedVec, right(T,2,k))
		Ac_mul_B!( Z, T, T.tmpMulcVec, 1, N[2]-vm+k )

		# Upper
		hadc!( T.tmpMulcVec, T.weigthedVec, left(T,1,k) )
		for m in 1:M
			@inbounds T.tmpMulcVec[m] *= conj(T.diag[2,m])
		end
		z = slice(Z, k, vm+1:N[2]-vm)
		NFFT.nfft_adjoint!( T.NFFTy, T.tmpMulcVec, z )

		# Lower
		hadc!( T.tmpMulcVec, T.weigthedVec, right(T,1,k) )
		for m in 1:M
			@inbounds T.tmpMulcVec[m] *= conj(T.diag[2,m])
		end
		z = slice(Z, N[1]-vm+k, vm+1:N[2]-vm)
		NFFT.nfft_adjoint!( T.NFFTy, T.tmpMulcVec, z )
	end

	# Internal coefficients
	for m in 1:M
		@inbounds T.tmpMulVec[m] = v[m]
		for d in 1:2
			@inbounds T.tmpMulVec[m] *= conj(T.diag[d,m])
		end
	end
	isuniform(T) || had!(T.tmpMulVec, get(T.weights))
	NFFT.nfft_adjoint!(T.NFFT, T.tmpMulVec, S.internal)

	return Z
end

function Base.Ac_mul_B!(z::DenseVector{Complex{Float64}}, T::Freq2Wave2D, v::DenseVector{Complex{Float64}})
	size(T,2) == length(z) || throw(DimensionMismatch())

	Z = reshape(z, wsize(T))
	Ac_mul_B!(Z, T, v)

	return z
end

function Base.Ac_mul_B(T::Freq2Wave, v::AbstractVector)
	if !isa(v, Array{Complex{Float64}})
		v = map(Complex{Float64}, v)
	end

	z = Array{Complex{Float64}}(size(T,2))
	Ac_mul_B!(z, T, v)

	return z
end

function Base.(:(\))(T::Freq2Wave, Y::AbstractMatrix)
	length(Y) == (M = size(T,1)) || throw(DimensionMismatch())

	y = flatten_view(Y)
	x = T \ y
end

function Base.(:(\))(T::Freq2Wave, y::AbstractVector)
	if !isa(y, Array{Complex{Float64}})
		y = map(Complex{Float64}, y)
	end

	# Non-uniform samples: Scale observations
	if !isuniform(T)
		y .*= get(T.weights)
	end

	x0 = zeros(Complex{Float64}, wsize(T))
	x = cgnr(T, y, x0)
	#= x, h = lsqr(T, y) =#
end


@doc """
	collect(Freq2Wave) -> Matrix
	
Return the full change of basis matrix.

In 2D, the reconstruction grid is sorted by the `y` coordinate, i.e., the order is
(1,1),
(2,1),
(3,1),
(1,2),
(2,2),
(3,2)
etc
"""->
function Base.collect(T::Freq2NoBoundaryWave2D)
	M = size(T,1)
	Nx, Ny = wsize(T)
	F = Array{Complex{Float64}}(M, Nx*Ny)

	phi = prod(T.internal, 2)

	idx = 0
	for ny in 0:Ny-1, nx in 0:Nx-1
		idx += 1
		for m in 1:M
			@inbounds F[m,idx] = phi[m]*cis( -twoπ*(nx*T.NFFT.x[1,m] + ny*T.NFFT.x[2,m]) )
		end
	end

	if !isuniform(T)
		broadcast!( *, F, F, get(T.weights) )
	end

	return F
end

function ucollect(T::Freq2NoBoundaryWave2D)
	isuniform(T) || throw(AssertionError())

	M1, M2 = T.NFFT.n
	N1, N2 = T.NFFT.N

	F1 = Array{Complex{Float64}}(M1, N1)
	for n in 1:N1, m in 1:M2:M1
		@inbounds F1[m,n] = T.internal[m]*cis( -twoπ*T.NFFT.x[m]*(n-1) )
	end

	F2 = Array{Complex{Float64}}(M2, N2)
	for n in 1:N1, m in 1:M2
		@inbounds F1[m,n] = T.internal[m]*cis( -twoπ*T.NFFT.x[m]*(n-1) )
	end

	#kron(F1, F2)
	return F1, F2
end

function Base.collect(T::Freq2BoundaryWave2D)
	M = size(T,1)
	Nx, Ny = wsize(T)
	F = Array{Complex{Float64}}(M, Nx*Ny)

	phix = Array{Complex{Float64}}(M)
	phiy = similar(phix)

	idx = 0
	for ny in 0:Ny-1
		unsafe_FourScaling!(phiy, T, ny, 2)
		for nx in 0:Nx-1
			unsafe_FourScaling!(phix, T, nx, 1)
			had!(phix, phiy)
			F[:,idx+=1] = phix
		end
	end

	if !isuniform(T)
		broadcast!( *, F, F, get(T.weights) )
	end

	return F
end

@doc """
	unsafe_FourScaling!(phi, T::Freq2BoundaryWave{2}, n::Int, d::Int)

Replace `phi` with the `n`'th "column" from dimension `d` of `T`.
"""->
function unsafe_FourScaling!(phi::Vector{Complex{Float64}}, T::Freq2BoundaryWave2D, n::Integer, d::Integer)
	M = length(phi)
	N = wsize(T)[d]
	p = van_moment(T)

	if p <= n < N-p
		for m in 1:M
			@inbounds phi[m] = T.internal[m,d]*cis( -twoπ*n*T.NFFT.x[d,m] )
		end
	elseif 0 <= n < p
		so = n*M + 1
		unsafe_copy!( phi, 1, T.left[d], so, M ) 
	else
		so = (n-N+p)*M + 1
		unsafe_copy!( phi, 1, T.right[d], so, M ) 
	end
end


# ------------------------------------------------------------
# Common

function Base.size(T::Freq2Wave)
	( size(T,1), size(T,2) )
end

function Base.size(T::Freq2Wave, d::Integer)
	if d == 1
		size(T.internal, 1)
	elseif d == 2
		D = dim(T)
		2^(D*wscale(T))
	else
		throw(AssertionError())
	end
end

van_moment(T::Freq2Wave1D) = hasboundary(T) ? size(T.left,2) : van_moment(T.wavename)
van_moment(T::Freq2Wave2D) = hasboundary(T) ? size(T.left[1],2)::Int64 : van_moment(T.wavename)

function Base.eltype(::Freq2Wave)
	return Complex{Float64}
end

function Base.show(io::IO, T::Freq2Wave)
	D = dim(T)
	println(io, D, "D change of basis matrix")

	isuniform(T) ?  U = " " : U = " non-"
	M = size(T,1)
	println(io, "From: ", M, U, "uniform frequency samples")

	D == 1 ? N = size(T,2) : N = wsize(T)
	print(io, "To: ", N, " ", T.wavename, " wavelets")
end


