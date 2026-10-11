! SPDX-License-Identifier: GPL-3.0-or-later
! Complex-IQ AWGN and finite Gaussian-scatter HF channel simulation.
!
! The named HF conditions are the simulation settings used in this study.
! Two independently fading paths have ensemble mean
! powers 1/2 each; realizations are never power-normalized.
! B_D = 2*sigma_f [Hz]; rho(dt)=exp(-PI**2*B_D**2*dt**2/2).
! Each process uses 64 independent frequencies N(0,(B_D/2)**2) with CN(0,1/64)
! coefficients. The covariance is exact when averaged over frequencies and
! coefficients; a finite realization is Monte Carlo spectral quadrature.
! This finite line spectrum is not an exact continuous Gaussian spectrum.
!
! References:
! https://www.itu.int/rec/R-REC-F.1487-0-200005-I/en
! https://www.mathworks.com/help/comm/ug/hf-ionospheric-channel-models.html
!
! Noise: E|w|**2=fs*N0; each quadrature has variance fs*N0/2.
! SNR2500=P/(2500*N0), where reference active-frame TX power P=1.
! Noise is not rescaled to instantaneous faded receive power or signal BW.
module channel_mod
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite, ieee_is_nan
  use numerics_mod, only: dp, PI, rng_normal
  implicit none
  private
  public :: apply_channel, gaussian_fading, fractional_delay, channel_profile
  integer, parameter :: FADING_TONES=64, DELAY_TAPS=16
contains
  subroutine channel_profile(profile, delays_s, powers, default_doppler)
    character(len=*), intent(in) :: profile
    real(dp), allocatable, intent(out) :: delays_s(:), powers(:)
    real(dp), intent(out) :: default_doppler
    character(len=:), allocatable :: name
    integer :: i, c
    name=trim(adjustl(profile))
    do i=1,len(name)
      c=iachar(name(i:i))
      if(c>=iachar('A').and.c<=iachar('Z')) name(i:i)=achar(c+32)
    end do
    if(index(name,'hf_')==1) name=name(4:)
    select case(name)
    case('awgn')
      delays_s=[0.0_dp]; powers=[1.0_dp]; default_doppler=0.0_dp
    case('quiet')
      delays_s=[0.0_dp,0.0005_dp]; powers=[0.5_dp,0.5_dp]; default_doppler=0.1_dp
    case('moderate')
      delays_s=[0.0_dp,0.001_dp]; powers=[0.5_dp,0.5_dp]; default_doppler=1.0_dp
    case('hard')
      delays_s=[0.0_dp,0.002_dp]; powers=[0.5_dp,0.5_dp]; default_doppler=4.0_dp
    case default
      error stop 'Unknown channel: use awgn, quiet, moderate, hard'
    end select
  end subroutine channel_profile

  subroutine gaussian_fading(times_s, doppler_hz, gains)
    ! Unit ensemble power, not unit per-realization power. No states returned.
    real(dp), intent(in) :: times_s(:), doppler_hz
    complex(dp), allocatable, intent(out) :: gains(:)
    real(dp) :: frequencies(FADING_TONES), scale, delta, tolerance
    complex(dp) :: coefficients(FADING_TONES), oscillator(FADING_TONES)
    complex(dp) :: rotation(FADING_TONES)
    logical :: uniform
    integer :: i, k, n
    if(.not.ieee_is_finite(doppler_hz).or.doppler_hz<0.0_dp) &
      error stop 'Doppler B_D must be finite and nonnegative'
    if(any(.not.ieee_is_finite(times_s))) error stop 'Fading times must be finite'
    n=size(times_s); allocate(gains(n))
    if(n==0) return
    scale=1.0_dp/sqrt(2.0_dp*FADING_TONES)
    do k=1,FADING_TONES
      frequencies(k)=0.5_dp*doppler_hz*rng_normal()
      coefficients(k)=cmplx(rng_normal(),rng_normal(),dp)*scale
    end do
    if(doppler_hz<=0.0_dp) then
      gains=sum(coefficients)
      return
    end if
    uniform=.true.; delta=0.0_dp
    if(n>1) then
      delta=times_s(2)-times_s(1)
      tolerance=32.0_dp*epsilon(1.0_dp)*max(1.0_dp,maxval(abs(times_s)))
      if(n>2) uniform=all(abs(times_s(2:n)-times_s(1:n-1)-delta)<=tolerance)
    end if
    if(uniform) then
      oscillator=coefficients*exp(cmplx(0.0_dp,2.0_dp*PI*times_s(1)*frequencies,dp))
      rotation=exp(cmplx(0.0_dp,2.0_dp*PI*delta*frequencies,dp))
      do i=1,n
        ! Periodic exact reset bounds roundoff drift in long frames.
        if(mod(i-1,4096)==0.and.i>1) &
          oscillator=coefficients*exp(cmplx(0.0_dp,2.0_dp*PI*times_s(i)*frequencies,dp))
        gains(i)=sum(oscillator)
        oscillator=oscillator*rotation
      end do
    else
      do i=1,n
        gains(i)=sum(coefficients*exp(cmplx(0.0_dp,2.0_dp*PI*times_s(i)*frequencies,dp)))
      end do
    end if
  end subroutine gaussian_fading

  pure real(dp) function modified_bessel_i0(x) result(value)
    real(dp), intent(in) :: x
    real(dp) :: term
    integer :: k
    value=1.0_dp; term=1.0_dp
    do k=1,100
      term=term*(0.5_dp*x/real(k,dp))**2
      value=value+term
      if(abs(term)<epsilon(1.0_dp)*value) exit
    end do
  end function modified_bessel_i0

  subroutine fractional_delay(iq, delay_samples, delayed, n_taps)
    ! Default: 16-tap Kaiser(beta=6) windowed sinc. Integer delays are exact.
    ! Complex samples, including their phases, are convolved with a real FIR.
    ! FIR DC gain is calibrated once; no signal energy normalization is used.
    ! Centered FIR latency is removed. Negative-time interpolation ringing is
    ! cropped; positive-time ringing retained. TX shaping tails limit cropping.
    ! This is a finite FIR approximation and is inaccurate close to Nyquist.
    complex(dp), intent(in) :: iq(:)
    real(dp), intent(in) :: delay_samples
    complex(dp), allocatable, intent(out) :: delayed(:)
    integer, optional, intent(in) :: n_taps
    integer :: taps, left, right, whole, k, i, j, n
    real(dp) :: fraction, argument, coordinate, window
    real(dp), allocatable :: kernel(:)
    if(.not.ieee_is_finite(delay_samples).or.delay_samples<0.0_dp) &
      error stop 'Delay must be finite and nonnegative'
    if(size(iq)==0) error stop 'IQ cannot be empty'
    taps=DELAY_TAPS
    if(present(n_taps)) taps=n_taps
    if(taps<4.or.mod(taps,2)/=0) error stop 'Delay FIR needs an even tap count >=4'
    whole=floor(delay_samples); fraction=delay_samples-real(whole,dp); n=size(iq)
    if(abs(fraction)<1.0e-12_dp) then
      allocate(delayed(n+whole)); delayed=cmplx(0.0_dp,0.0_dp,dp)
      delayed(whole+1:whole+n)=iq
      return
    end if
    left=taps/2-1; right=taps/2
    allocate(kernel(-left:right))
    do k=-left,right
      argument=real(k,dp)-fraction
      coordinate=(real(k,dp)-0.5_dp)/(0.5_dp*real(taps-1,dp))
      window=modified_bessel_i0(6.0_dp*sqrt(max(0.0_dp,1.0_dp-coordinate**2)))/ &
             modified_bessel_i0(6.0_dp)
      if(abs(argument)<epsilon(1.0_dp)) then
        kernel(k)=window
      else
        kernel(k)=sin(PI*argument)/(PI*argument)*window
      end if
    end do
    kernel=kernel/sum(kernel)
    allocate(delayed(n+whole+right)); delayed=cmplx(0.0_dp,0.0_dp,dp)
    do i=1,n
      do k=-left,right
        j=i+whole+k
        if(j>=1.and.j<=size(delayed)) delayed(j)=delayed(j)+kernel(k)*iq(i)
      end do
    end do
  end subroutine fractional_delay

  subroutine apply_channel(iq, fs, snr_db, profile, doppler_hz, cfo_hz, drift_hz_s, &
                           offset_samples, noise_only, received, noise_variance)
    ! Negative doppler_hz selects the named profile default.
    ! Output length=N+offset+max(offset,ceil(max_delay*fs)+8).
    ! Suffix includes delayed signal/filter tails, with AWGN on every sample.
    ! t=0 is the frame start: CFO/drift phase=2*pi*(cfo*t+drift*t*t/2).
    ! Noise variance is a known experiment setting. No payload, channel gains,
    ! clean RX, actual timing, or actual CFO estimate is returned to a receiver.
    complex(dp), intent(in) :: iq(:)
    real(dp), intent(in) :: fs, snr_db, doppler_hz, cfo_hz, drift_hz_s
    character(len=*), intent(in) :: profile
    integer, intent(in) :: offset_samples
    logical, intent(in) :: noise_only
    complex(dp), allocatable, intent(out) :: received(:)
    real(dp), intent(out) :: noise_variance
    real(dp), allocatable :: delays_s(:), powers(:), times(:)
    complex(dp), allocatable :: signal(:), delayed(:), gains(:)
    real(dp) :: spread, default_doppler, noise_scale, t, phase
    integer :: n, suffix, n_signal, p, i
    if(size(iq)==0) error stop 'IQ cannot be empty'
    if(any(.not.ieee_is_finite(real(iq,dp))).or.any(.not.ieee_is_finite(aimag(iq)))) &
      error stop 'IQ must be finite'
    if(.not.ieee_is_finite(fs).or.fs<=0.0_dp) error stop 'fs must be positive and finite'
    if(ieee_is_nan(snr_db).or.(.not.ieee_is_finite(snr_db).and.snr_db<0.0_dp)) &
      error stop 'SNR must be finite or positive infinity'
    if(.not.ieee_is_finite(doppler_hz)) error stop 'Doppler argument must be finite'
    if(.not.ieee_is_finite(cfo_hz).or..not.ieee_is_finite(drift_hz_s)) &
      error stop 'CFO and drift must be finite'
    if(offset_samples<0) error stop 'Offset must be nonnegative'
    call channel_profile(profile,delays_s,powers,default_doppler)
    spread=doppler_hz
    if(spread<0.0_dp) spread=default_doppler
    if(size(delays_s)==1.and.spread>0.0_dp) error stop 'Use an HF profile for Doppler spread'
    n=size(iq); suffix=max(offset_samples,ceiling(maxval(delays_s)*fs)+DELAY_TAPS/2)
    n_signal=n+suffix
    allocate(signal(n_signal),times(n_signal)); signal=cmplx(0.0_dp,0.0_dp,dp)
    do i=1,n_signal
      times(i)=real(i-1,dp)/fs
    end do
    if(.not.noise_only) then
      if(size(delays_s)==1) then
        signal(1:n)=iq
      else
        do p=1,size(delays_s)
          call fractional_delay(iq,delays_s(p)*fs,delayed)
          call gaussian_fading(times(:size(delayed)),spread,gains)
          signal(:size(delayed))=signal(:size(delayed))+sqrt(powers(p))*gains*delayed
        end do
      end if
      do i=1,n_signal
        t=times(i); phase=2.0_dp*PI*(cfo_hz*t+0.5_dp*drift_hz_s*t*t)
        signal(i)=signal(i)*cmplx(cos(phase),sin(phase),dp)
      end do
    end if
    allocate(received(offset_samples+n_signal)); received=cmplx(0.0_dp,0.0_dp,dp)
    received(offset_samples+1:)=signal
    if(.not.ieee_is_finite(snr_db)) then
      noise_variance=0.0_dp
    else
      ! Negative exponent avoids overflow for very high positive SNR.
      noise_variance=(fs/2500.0_dp)*10.0_dp**(-snr_db/10.0_dp)
    end if
    if(.not.ieee_is_finite(noise_variance)) error stop 'SNR gives unrepresentable noise variance'
    noise_scale=sqrt(noise_variance/2.0_dp)
    if(noise_variance>0.0_dp) then
      do i=1,size(received)
        received(i)=received(i)+noise_scale*cmplx(rng_normal(),rng_normal(),dp)
      end do
    end if
  end subroutine apply_channel
end module channel_mod
