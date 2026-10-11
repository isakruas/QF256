module numerics_mod
  use iso_fortran_env, only: real64
  implicit none
  integer, parameter :: dp=real64
  real(dp), parameter :: PI=acos(-1.0_dp)
contains
  subroutine seed_rng(seed)
    integer, intent(in) :: seed
    integer :: n,i
    integer, allocatable :: values(:)
    call random_seed(size=n)
    allocate(values(n))
    do i=1,n
      values(i)=modulo(seed+104729*i,huge(1)-1)
    end do
    call random_seed(put=values)
  end subroutine
  function rng_uniform() result(x)
    real(dp) :: x
    call random_number(x)
    x=max(x,tiny(1.0_dp))
  end function
  function rng_normal() result(x)
    real(dp) :: x
    x=sqrt(-2*log(rng_uniform()))*cos(2*PI*rng_uniform())
  end function
  subroutine invert_hpd(a,ainv,logdet)
    complex(dp), intent(in) :: a(:,:)
    complex(dp), intent(out) :: ainv(:,:)
    real(dp), intent(out) :: logdet
    complex(dp) :: l(size(a,1),size(a,1)),v(size(a,1)),z(size(a,1)),q
    integer :: n,i,j,k
    n=size(a,1); l=0; logdet=0
    do i=1,n
      do j=1,i
        q=a(i,j)
        do k=1,j-1
          q=q-l(i,k)*conjg(l(j,k))
        end do
        if(i==j) then
          l(i,j)=sqrt(max(real(q,dp),1e-14_dp))
          logdet=logdet+2*log(real(l(i,j),dp))
        else
          l(i,j)=q/l(j,j)
        end if
      end do
    end do
    do k=1,n
      v=0; z=0
      do i=1,n
        q=0
        if(i==k) q=1
        do j=1,i-1
          q=q-l(i,j)*v(j)
        end do
        v(i)=q/l(i,i)
      end do
      do i=n,1,-1
        q=v(i)
        do j=i+1,n
          q=q-conjg(l(j,i))*z(j)
        end do
        z(i)=q/conjg(l(i,i))
      end do
      ainv(:,k)=z
    end do
  end subroutine
  function logsumexp(x) result(v)
    real(dp), intent(in) :: x(:)
    real(dp) :: v,m
    m=maxval(x); v=m+log(sum(exp(x-m)))
  end function
  subroutine wilson(failures,n,lo,hi)
    integer, intent(in) :: failures,n
    real(dp),intent(out) :: lo,hi
    real(dp) :: p,d,c,r
    p=real(failures,dp)/n; d=1+1.96_dp**2/n
    c=(p+1.96_dp**2/(2*n))/d
    r=1.96_dp*sqrt(p*(1-p)/n+1.96_dp**2/(4*n*n))/d
    lo=max(0.0_dp,c-r); hi=min(1.0_dp,c+r)
  end subroutine
end module
