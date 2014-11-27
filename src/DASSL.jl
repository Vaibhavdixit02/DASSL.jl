module DASSL

include("counters.jl")

import Base: start, next, done

export dasslIterator, dasslSolve

# there is no factorize for scalars in Base
Base.factorize(x::Number) = x


const MAXORDER = 6


immutable DAE
    F :: Function
    y0; tstart
    reltol; abstol
    initstep; maxstep; minstep; maxorder; dy0; tstop
    norm; weights
    factorizeJacobian
end


function dasslIterator(F :: Function,
                       y0,
                       tstart;
                       reltol   = 1/10^3,
                       abstol   = 1/10^5,
                       initstep = 1/10^4,
                       maxstep  = Inf,
                       minstep  = 0,
                       maxorder = MAXORDER,
                       dy0      = zero(y0),
                       tstop    = Inf,
                       norm     = dassl_norm,
                       weights  = dassl_weights,
                       factorizeJacobian = true, # whether to store factorized version of jacobian
                       args...)

    return DAE(F,y0,tstart,
               reltol,abstol,
               initstep,maxstep,minstep,maxorder,dy0,tstop,
               norm,weights,
               factorizeJacobian)
end


# parameters for the Newton method.  a is a convergence coefficient in
# the modified Newton method.  jac holds a Jacobian of a function
# F(t,y,a*y+b) with a and b defined in the stepper!.  The type of jac
# depends.
type Newton
    a :: Real
    jac
end

function Newton{T<:Number}(y0::Vector{T})
    a = zero(T)
    jac = zeros(T,length(y0),length(y0))
    Newton(a,jac)
end

function Newton(y0::Number)
    Newton(zero(y0),zero(y0))
end

function Newton(::Any)
    error("Unsupported type of initial data, y0 should be a Number of a Vector{Number}")
end


type DAEstate
    tout    :: Vector
    yout    :: Vector
    dyout   :: Vector
    h       :: Real
    newton  :: Newton           # parameters for Newton method
    stop    :: Bool
    counter :: Counter          # see counters.jl
    order   :: Int              # last order
    r       :: Real                # last stepsize multiplier
end


done(::DAE,state::DAEstate) = state.stop


function start(dae::DAE)
    tout  = [dae.tstart]        # initial time
    yout  = Array(typeof(dae.y0),0)
    push!(yout,dae.y0)
    dyout  = Array(typeof(dae.dy0),0)
    push!(dyout,dae.dy0)

    h0    = dae.initstep
    return DAEstate(tout,yout,dyout,
                    h0,Newton(dae.y0),
                    false,Counter(),1,one(h0))
end


function next(dae::DAE, state::DAEstate)

    # repeat until the step converges
    while true

        t = state.tout[end]
        h = min(state.h, dae.maxstep, dae.tstop-t)
        hmin = max(4*eps(typeof(h)),dae.minstep)

        if h < hmin             # h < 0 will catch t > dae.tstop
            info("Stepsize too small (h=$h at t=$t.")
            error("Define return 2")
            break
        elseif state.counter.rejected_current >= -2/3*log(eps(typeof(h)))
            info("Too many ($num_fail) failed steps in a row (h=$h at t=$t.")
            error("Define return 3")
            break
        end

        # error weights
        wt = dae.weights(state.yout[end],dae.reltol,dae.abstol)
        normy(v) = norm(v,wt)

        (status,err,yn,dyn)=stepper!(state,dae,h,wt,normy)

        if status < 0
            # Early failure: Newton iteration failed to converge, reduce
            # the step size and try again

            # update the step counter
            rejected!(state.counter)

            # reduce the step by 25% and try again
            h *= 1/4
            continue

        elseif err > 1
            # local error is too large.  Step is rejected, and we try
            # again with new step size and order.

            rejected!(state.counter)

            # determine the new step size and order, excluding the current step
            (r,ord) = newStepOrder(state,dae,h,normy,err)
            h *= r
            continue

        else
            ####################
            # step is accepted #
            ####################

            accepted!(state.counter)
            push_step!(state,t+h,yn,dyn)

            # determine the new step size and order, including the current step
            (r_new,ord_new) = newStepOrder(state,dae,h,normy,err)

            if ord_new == state.order && r_new == state.r
                order_unchanged!(state.counter)
            else
                order_changed!(state.counter)
            end

            (state.r,state.order) = (r_new,ord_new)
            state.h *= state.r

            out = (state.tout[end],state.yout[end],state.dyout[end])

            return (out,state)

        end

    end

end

# If the step is accepted we push it to the top if we have more than
# MAXORDER+3 of steps stored we delete the oldest ones.
function push_step!(state::DAEstate,t,y,dy)
    push!(state.tout,t)
    push!(state.yout,y)
    push!(state.dyout,dy)
    if length(state.tout) > MAXORDER+3
        shift!(state.tout)
        shift!(state.yout)
        shift!(state.dyout)
    end
end


# solves the equation F with initial data y0 over for times t in tspan=[t0,t1]
function dasslSolve(F, y0, tspan; dy0 = zero(y0), args...)
    tout  = Array(typeof(tspan[1]),1)
    yout  = Array(typeof(y0),1)
    dyout = Array(typeof(y0),1)
    tout[1]  = tspan[1]
    yout[1]  = y0
    dyout[1] = dy0
    for (t, y, dy) in dasslIterator(F, y0, tspan[1]; dy0=dy0, tstop=tspan[end], args...)
        push!( tout,  t)
        push!( yout,  y)
        push!(dyout, dy)
        if t >= tspan[end]
            break
        end
    end
    return (tout,yout,dyout)
end


function newStepOrder(state::DAEstate,
                      dae :: DAE,
                      h :: Real,
                      normy :: Function,
                      erk :: Real)

    t        = [state.tout,state.tout[end]+h]
    k        = state.order
    num_fail = state.counter.rejected_current
    maxorder = dae.maxorder
    y        = state.yout

    if length(t) != length(y)+1
        error("incompatible size of y and t")
    end

    available_steps = length(t)

    if num_fail >= 3
        # probably, the step size was drastically decreased for
        # several steps in a row, so we reduce the order to one and
        # further decrease the step size
        (r,order) = (1/4,1)

    elseif available_steps < k+3
        # we are at the beginning of the integration, we don't have
        # enough steps to run newStepOrderContinuous, we have to rely
        # on a crude order/stepsize selection
        if num_fail == 0
            # previous step was accepted so we can increase the order
            # and the step size
            (r,order) = (2,min(k+1,maxorder))
        else
            # @todo I am not sure about the choice of order
            #
            # previous step was rejected, we have to decrease the step
            # size and order
            (r,order) = (1/4,max(k-1,1))
        end

    else
        # we have at least k+3 previous steps available, so we can
        # safely estimate the order k-2, k-1, k and possibly k+1
        (r,order) = newStepOrderContinuous(t,y,normy,k,state.counter.fixed,erk,maxorder)
        # this function prevents from step size changing too rapidly
        r = normalizeStepSize(r,num_fail)
        # if the previous step failed don't increase the order
        if num_fail > 0
            order = min(order,k)
        end

    end

    return r, order

end


function newStepOrderContinuous(t        :: Vector,
                                y        :: Vector,
                                normy    :: Function,
                                k        :: Int,
                                nfixed   :: Int,
                                erk      :: Real,
                                maxorder :: Int)

    # compute the error estimates of methods of order k-2, k-1, k and
    # (if possible) k+1
    errors  = errorEstimates(t,y,normy,k,nfixed,maxorder)
    errors[k] = erk
    # normalized errors, this is TERK from DASSL
    nerrors = errors .* [2:maxorder+1]

    order = k

    if k == maxorder
        order = k

    elseif k == 1
        if nerrors[k]/2 > nerrors[k+1]
            order = k+1
        end

    elseif k >= 2
        if k == 2 && nerrors[k-1] < nerrors[k]/2
            order = k-1
        elseif k >= 3 && max(nerrors[k-1],nerrors[k-2]) <= nerrors[k]
            order = k-1
        elseif false
            # @todo don't increase order two times in a row
            order = k
        elseif nfixed >= k+1
            # if the estimate for order k+1 is available
            if nerrors[k-1] <= min(nerrors[k],nerrors[k+1])
                order = k-1
            elseif nerrors[k] <= nerrors[k+1]
                order = k
            else
                order = k+1
            end
        end
    end

    # error estimate for the next step
    est = errors[order]

    # initial guess for the new step size multiplier
    r = (2*est+1/10000)^(-1/(order+1))

    return r, order

end


# Based on whether the previous steps were successful we determine
# the new step size
#
# num_fail is the number of steps that failed before this step, r is a
# suggested step size multiplier.
function normalizeStepSize(r :: Real, num_fail :: Int)

    if num_fail == 0
        # previous step was accepted
        if r >= 2
            r = 2
        elseif r < 1
            # choose r from between 0.5 and 0.9
            r = max(1/2,min(r,9/10))
        else
            r = 1
        end

    elseif num_fail == 1
        # previous step failed, we slightly decrease the step size,
        # the resulting r is between 0.25 and 0.9
        r = max(1/4,9/10*min(r,1))

    elseif num_fail == 2
        # previous step failed for a second time, error estimates are
        # probably not reliable so decrease the step size
        r = 1/4

    end

    return r

end



# this function estimates the errors of methods of order k-2,k-1,k,k+1
# and returns the estimates as an array seq the estimates require

# here t is an array of times    [t_1, ..., t_n, t_{n+1}]
# and y is an array of solutions [y_1, ..., y_n]
function errorEstimates(t        :: Vector,
                        y        :: Vector,
                        normy    :: Function,
                        k        :: Int,
                        nfixed   :: Int,
                        maxorder :: Int)

    h = diff(t)

    l = length(y[1])

    psi    = cumsum(reverse(h[end-k-1:end]))

    # @todo there is no need to allocate array of size 1:k+3, we only
    # need a four element array k:k+3
    phi    = zeros(eltype(y[1]),l,k+3)
    # fill in all but a last (k+3)-rd row of phi
    for i = k:k+2
        phi[:,i] = prod(psi[1:i-1])*interpolateHighestDerivative(t[end-i+1:end],y[end-i+1:end])
    end

    sigma  = zeros(eltype(t),k+2)
    sigma[1] = 1
    for i = 2:k+2
        sigma[i] = (i-1)*sigma[i-1]*h[end]/psi[i]
    end

    errors    = zeros(eltype(t),maxorder)
    errors[k] = sigma[k+1]*normy(phi[:,k+2])

    if k >= 2
        # error estimate for order k-1
        errors[k-1] = sigma[k]*normy(phi[:,k+1])
    end

    if k >= 3
        # error estimate for order k-2
        errors[k-2] = sigma[k-1]*normy(phi[:,k])
    end

    if k+1 <= maxorder && nfixed >= k+1
        # error estimate for order k+1
        # fill in the rest of the phi array (the (k+3)-rd row)
        for i = k+3:k+3
            phi[:,i] = prod(psi[1:i-1])*interpolateHighestDerivative(t[end-i+1:end],y[end-i+1:end])
        end

        # estimate for the order k+1
        errors[k+1] = normy(phi[:,k+3])
    end

    # return error estimates (this is ERK{M2,M1,,P1} from DASSL)
    return errors

end

# state.t is an array [t_1,...,t_n] of length n
# state.y is a matrix [y_1,...,y_n] of size k x l, the same for state.dy
# h_next is a size of next step
# dae encodes the fixed parameters of the DAE (including a function we
#     solve dae.F(y,y',t)=0).
# wt is a vector of weights of the norm
function stepper!(state  :: DAEstate,
                  dae    :: DAE,
                  h_next :: Real,
                  wt,
                  norm   :: Function)

    ord      = state.order
    t        = state.tout
    y        = state.yout
    dy       = state.dyout

    l        = length(y[1])        # the number of dependent variables

    # sanity check
    # @todo remove it in final version
    if length(t) < ord || length(y) < ord
        error("Not enough points in a grid to use method of order $ord")
    end

    # @todo this should be the view of the tail of the arrays t and y
    tk = t[end-ord+1:end]
    yk = y[end-ord+1:end]

    # check whether order is between 1 and 6, for orders higher than 6
    # BDF does not converge
    if ord < 1 || ord > dae.maxorder
        error("Order ord=$(ord) should be [1,...,$(dae.maxorder)]")
        return(-1)
    end

    t_next   = tk[end]+h_next

    if length(y) == 1
        # this is the first step, we initialize y0 and dy0 with
        # initial data provided by user
        dy0 = dy[1]
        y0  = y[1]+h_next*dy[1]
    else
        # we use predictor to obtain the starting point for the
        # modified newton method
        #
        # @todo I should optimize the following functions to return a
        # tuple (y0,dy0)
        dy0 = interpolateDerivativeAt(tk,yk,t_next)
        y0  = interpolateAt(tk,yk,t_next)
    end

    # I think there is an error in the book, the sum should be taken
    # from j=1 to k+1 instead of j=1 to k
    alphas = -sum([1/j for j=1:ord])

    a=-alphas/h_next
    b=dy0-a*y0

    # delta for approximation of jacobian.  I removed the
    # sign(h_next*dy0) from the definition of delta because it was
    # causing trouble when dy0==0 (which happens for ord==1)
    ep    = eps(one(eltype(abs(y0)))) # this is the machine epsilon
    delta = max(abs(y0),abs(h_next*dy0),wt)*sqrt(ep)

    # f_newton is supplied to the modified Newton method.  Zeroes of
    # f_newton give the corrected value of the next step "yc"
    f_newton(yc)=dae.F(t_next,yc,a*yc+b)

    # if called, this function computes the jacobian of f_newton at
    # the point y0 via first order finite differences
    g_new()=G(f_newton,y0,delta)

    # this is the updated value of coefficient a, if jacobian is
    # udpated, corrector will replace state.newton.a with a_new
    a_new=a

    # we compute the corrected value "yc", updating the gradient if necessary
    (status,yc)=corrector(state.newton, # old coefficient a and jacobian
                          a_new,    # current coefficient a
                          g_new,    # this function is called when new jacobian is needed
                          y0,       # starting point for modified newton
                          f_newton, # we want to find zeroes of this function
                          norm,     # the norm used to estimate error needs weights
                          dae.factorizeJacobian)

    alpha = Array(eltype(t),ord+1)

    for i = 1:ord
        alpha[i] = h_next/(t_next-t[end-i+1])
    end

    if length(t) >= ord+1
        t0 = t[end-ord]
    elseif length(t) >= 2
        # @todo we choose some arbitrary value of t[0], here t[0]:=t[1]-(t[2]-h[1])
        h1 = t[2]-t[1]
        t0 = t[1]-h1
    else
        t0 = t[1]-h_next
    end

    alpha[ord+1] = h_next/(t_next-t0)

    alpha0 = -sum(alpha[1:ord])
    M      =  max(alpha[ord+1],abs(alpha[ord+1]+alphas-alpha0))
    err    =  norm((yc-y0))*M


    # status<0 means the modified Newton method did not converge
    # err is the local error estimate from taking the step
    # yc is the estimated value at the next step
    return (status, err, yc, a*yc+b)

end


# returns the corrected value yc and status.  If needed it updates
# the jacobian g_old and a_old.

function corrector(newton   :: Newton,
                   a_new    :: Real,
                   g_new    :: Function,
                   y0,
                   f_newton :: Function,
                   norm     :: Function,
                   factorizeJacobian :: Bool)

    # if a_old == 0 the new jacobian is always computed, independently
    # of the value of a_new
    if abs((newton.a-a_new)/(newton.a+a_new)) > 1/4
        # old jacobian wouldn't give fast enough convergence, we have
        # to compute a current jacobian
        newton.jac=g_new()
        if factorizeJacobian
            newton.jac=Base.factorize(newton.jac)
        end
        newton.a=a_new
        # run the corrector
        (status,yc)=newton_iteration( x->(-(newton.jac\f_newton(x))), y0, norm)
    else
        # old jacobian should give reasonable convergence
        c=2*newton.a/(a_new+newton.a)     # factor "c" is used to speed up
        # the convergence when using an
        # old jacobian
        # reusing the old jacobian
        (status,yc)=newton_iteration( x->(-c*(newton.jac\f_newton(x))), y0, norm)

        if status < 0
            # the corrector did not converge, so we recompute jacobian and try again
            newton.jac=g_new()
            if factorizeJacobian
                newton.jac=Base.factorize(newton.jac)
            end
            newton.a=a_new
            # run the corrector again
            (status,yc)=newton_iteration( x->(-(newton.jac\f_newton(x))), y0, norm)
        end
    end

    return (status,yc)

end


# this function iterates f until it finds its fixed point, starting
# from f(y0).  The result either satisfies norm(yn-f(yn))=0+... or is
# set back to y0.  Status tells if the fixed point was obtained
# (status==0) or not (status==-1).
function newton_iteration(f    :: Function,
                          y0,
                          norm :: Function)

    # first guess comes from the predictor method, then we compute the
    # second guess to get the norm1

    delta=f(y0)
    norm1=norm(delta)
    yn=y0+delta

    # after the first iteration the norm turned out to be very small,
    # terminate and return the first correction step

    ep    = eps(one(eltype(abs(y0)))) # this is the epsilon for type y0

    if norm1 < 10*ep
        status=0
        return(status,yn)
    end

    # maximal number of iterations is set by dassl algorithm to 4

    for i=1:3

        delta=f(yn)
        normn=norm(delta)
        rho=(normn/norm1)^(1/i)
        yn=yn+delta

        # iteration failed to converge

        if rho > 9/10
            status=-1
            return(status,y0)
        end

        err=rho/(1-rho)*normn

        # iteration converged successfully

        if err < 1/3
            status=0
            return(status,yn)
        end

    end

    # unable to converge after 4 iterations

    status=-1
    return(status,y0)
end


function dassl_norm(v, wt)
    norm(v./wt)/sqrt(length(v))
end

function dassl_weights(y,reltol,abstol)
    reltol*abs(y).+abstol
end


# compute the G matrix from dassl (jacobian of F(t,x,a*x+b))
# @todo replace with symmetric finite difference?

# Number version
function G(f     :: Function,
           y0    :: Number,
           delta :: Number)
    return (f(y0+delta)-f(y0))/delta
end

# Vector version
function G(f     :: Function,
           y0    :: Vector,
           delta :: Vector)
    n=length(y0)
    edelta=diagm(delta)
    s=Array(eltype(y0),n,n)
    for i=1:n
        s[:,i]=(f(y0+edelta[:,i])-f(y0))/delta[i]
    end
    return(s)
end

# returns the value of the interpolation polynomial at the point x0
function interpolateAt{T<:Real}(x::Vector{T},
                                y::Vector,
                                x0::T)

    if length(x)!=length(y)
        error("x and y have to be of the same size.")
    end

    n = length(x)
    p = zero(y[1])

    for i=1:n
        Li =one(T)
        for j=1:n
            if j==i
                continue
            else
                Li*=(x0-x[j])/(x[i]-x[j])
            end
        end
        p+=Li*y[i]
    end
    return p
end


# returns the value of the derivative of the interpolation polynomial
# at the point x0
function interpolateDerivativeAt{T<:Real}(x::Vector{T},
                                          y::Vector,
                                          x0::T)

    if length(x)!=length(y)
        error("x and y have to be of the same size.")
    end

    n = length(x)
    p = zero(y[1])

    for i=1:n
        dLi=zero(T)
        for k=1:n
            if k==i
                continue
            else
                dLi1=one(T)
                for j=1:n
                    if j==k || j==i
                        continue
                    else
                        dLi1*=(x0-x[j])/(x[i]-x[j])
                    end
                end
                dLi+=dLi1/(x[i]-x[k])
            end
        end
        p+=dLi*y[i]
    end
    return p
end


# if the interpolating polynomial is given as
# p(x)=a_{k-1}*x^{k-1}+...a_1*x+a_0 then this function returns the
# k-th derivative of p, i.e. (k-1)!*a_{k-1}
function interpolateHighestDerivative(x::Vector,
                                      y::Vector)

    if length(x)!=length(y)
        error("x and y have to be of the same size.")
    end

    n = length(x)
    p = zero(y[1])

    for i=1:n
        Li =one(eltype(x))
        for j=1:n
            if j==i
                continue
            else
                Li*=1/(x[i]-x[j])
            end
        end
        p+=Li*y[i]
    end
    return p
end

end
