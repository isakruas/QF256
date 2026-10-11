! Physical metrics for complex IQ in Fortran 2008.
module v2metrics_mod
  use iso_fortran_env, only: real64,int64
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
  implicit none
  private
  integer,parameter :: dp=real64
  real(dp),parameter :: pi=acos(-1.0_dp)
  type fft_plan
    integer :: n=0
    complex(dp),allocatable :: root(:)
  end type fft_plan
  type(fft_plan),save :: plans(4)
  public :: waveform_metrics,fft_forward
contains
  subroutine fft_forward(x)
    ! Unnormalized radix-2 forward FFT. Twiddle cache supports serial callers;
    ! use separate processes rather than sharing this cache between threads.
    complex(dp),intent(inout) :: x(:)
    complex(dp) :: temp,u,v
    integer :: n,p,i,j,k,bit,stage,half,first,stride
    real(dp) :: phase
    n=size(x)
    if(n<1.or.iand(n,n-1)/=0) error stop 'FFT requires a positive power-of-two size'
    p=0
    do i=1,size(plans)
      if(plans(i)%n==n) p=i
    end do
    if(p==0) then
      do i=1,size(plans)
        if(plans(i)%n==0) then
          p=i
          exit
        end if
      end do
      if(p==0) p=1
      if(allocated(plans(p)%root)) deallocate(plans(p)%root)
      allocate(plans(p)%root(0:n/2-1))
      plans(p)%n=n
      do i=0,n/2-1
        phase=-2.0_dp*pi*real(i,dp)/real(n,dp)
        plans(p)%root(i)=cmplx(cos(phase),sin(phase),dp)
      end do
    end if
    ! Incremental bit reversal, O(N) operations and no N-element index table.
    j=0
    do i=0,n-1
      if(j>i) then
        temp=x(i+1);x(i+1)=x(j+1);x(j+1)=temp
      end if
      bit=n/2
      do while(bit>0)
        if(iand(j,bit)==0) exit
        j=ieor(j,bit)
        bit=bit/2
      end do
      if(bit>0) j=ieor(j,bit)
    end do
    stage=2
    do while(stage<=n)
      half=stage/2
      stride=n/stage
      do first=0,n-1,stage
        do k=0,half-1
          u=x(first+k+1)
          v=plans(p)%root(k*stride)*x(first+k+half+1)
          x(first+k+1)=u+v
          x(first+k+half+1)=u-v
        end do
      end do
      if(stage==n) exit
      stage=2*stage
    end do
  end subroutine fft_forward

  subroutine waveform_metrics(iq,fs,papr,bw99,energy,peak,avg,lower_hz,upper_hz,fft_length)
    ! peak and avg are POWERS, not amplitudes. papr is 10*log10(peak/avg).
    ! energy=sum(|IQ|^2)/fs covers the supplied complete active frame.
    ! OBW99 is f(99.5%)-f(0.5%) of the two-sided, ordered power spectrum,
    ! with linear interpolation within FFT bins; no additional window is used.
    ! FFT length is next power of two >= 4*Ns. Nominal bin uncertainty ~fs/NFFT.
    ! A band that wraps across +/-fs/2 is not unwrapped by this definition.
    complex(dp),intent(in) :: iq(:)
    real(dp),intent(in) :: fs
    real(dp),intent(out) :: papr,bw99,energy,peak,avg
    real(dp),intent(out),optional :: lower_hz,upper_hz
    integer,intent(out),optional :: fft_length
    complex(dp),allocatable :: spectrum(:)
    real(dp),allocatable :: power(:)
    real(dp) :: total,df,lo,hi
    integer :: nf,ns
    integer(int64) :: wanted
    if(.not.ieee_is_finite(fs).or.fs<=0.0_dp) error stop 'positive finite sample rate required'
    ns=size(iq)
    if(ns<1) error stop 'nonempty IQ vector required'
    if(.not.all(ieee_is_finite(real(iq,dp))).or..not.all(ieee_is_finite(aimag(iq)))) &
      error stop 'finite IQ samples required'
    total=sum(abs(iq)**2)
    avg=total/real(ns,dp)
    energy=total/fs
    peak=maxval(abs(iq)**2)
    papr=0.0_dp;bw99=0.0_dp
    if(present(lower_hz)) lower_hz=0.0_dp
    if(present(upper_hz)) upper_hz=0.0_dp
    if(present(fft_length)) fft_length=0
    if(total<=tiny(1.0_dp)) return
    papr=10.0_dp*log10(peak/avg)
    wanted=4_int64*int(ns,int64)
    nf=1
    do while(int(nf,int64)<wanted)
      if(nf>ishft(huge(nf),-1)) error stop 'FFT size exceeds integer addressable range'
      nf=2*nf
    end do
    allocate(spectrum(nf),power(nf))
    spectrum=cmplx(0.0_dp,0.0_dp,dp)
    spectrum(1:ns)=iq
    call fft_forward(spectrum)
    power(1:nf/2)=abs(spectrum(nf/2+1:nf))**2
    power(nf/2+1:nf)=abs(spectrum(1:nf/2))**2
    total=sum(power)
    df=fs/real(nf,dp)
    lo=power_quantile(power,0.005_dp*total,df)
    hi=power_quantile(power,0.995_dp*total,df)
    bw99=hi-lo
    if(present(lower_hz)) lower_hz=lo
    if(present(upper_hz)) upper_hz=hi
    if(present(fft_length)) fft_length=nf
  end subroutine waveform_metrics

  real(dp) function power_quantile(power,target,df) result(f)
    real(dp),intent(in) :: power(:),target,df
    real(dp) :: cumulative,fraction
    integer :: i,n
    n=size(power)
    cumulative=0.0_dp
    do i=1,n
      if(cumulative+power(i)>=target.and.power(i)>0.0_dp) then
        fraction=(target-cumulative)/power(i)
        f=(real(i-1-n/2,dp)-0.5_dp+fraction)*df
        return
      end if
      cumulative=cumulative+power(i)
    end do
    f=(real(n/2,dp)-0.5_dp)*df
  end function power_quantile
end module v2metrics_mod
