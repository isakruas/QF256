! SPDX-License-Identifier: GPL-3.0-or-later
program test_channel
  use, intrinsic :: ieee_arithmetic, only: ieee_value, ieee_positive_inf
  use numerics_mod, only: dp, PI, seed_rng
  use channel_mod, only: channel_profile, fractional_delay, gaussian_fading, apply_channel
  use study_frontend_mod, only: frontend_capture
  implicit none
  real(dp), parameter :: fs=12000.0_dp
  real(dp), allocatable :: delays(:), powers(:)
  complex(dp), allocatable :: input(:), output(:), repeated(:), gains(:), shifted(:)
  real(dp) :: spread, variance, infinity, t, phase, measured, expected, second_moment, fourth_moment
  complex(dp) :: covariance, mean_gain
  integer :: checks, i

  checks=0
  infinity=ieee_value(0.0_dp,ieee_positive_inf)
  ! ITU-R F.1487 Annex 3, sections 3.1--3.3, mid-latitude profiles.
  ! Doppler width is 2*sigma, not sigma or the fading-rate half-width.
  call channel_profile('quiet',delays,powers,spread)
  call check(size(delays)==2.and.size(powers)==2,'quiet path count')
  call check(maxval(abs(delays-[0.0_dp,0.0005_dp]))<1e-14_dp,'quiet delays')
  call check(maxval(abs(powers-0.5_dp))<1e-14_dp.and.abs(spread-0.1_dp)<1e-14_dp,'quiet power and spread')
  call channel_profile('moderate',delays,powers,spread)
  call check(size(delays)==2.and.size(powers)==2,'moderate path count')
  call check(maxval(abs(delays-[0.0_dp,0.001_dp]))<1e-14_dp,'moderate delays')
  call check(maxval(abs(powers-0.5_dp))<1e-14_dp.and.abs(spread-0.5_dp)<1e-14_dp,'moderate power and spread')
  call channel_profile('disturbed',delays,powers,spread)
  call check(size(delays)==2.and.size(powers)==2,'disturbed path count')
  call check(maxval(abs(delays-[0.0_dp,0.002_dp]))<1e-14_dp,'disturbed delays')
  call check(maxval(abs(powers-0.5_dp))<1e-14_dp.and.abs(spread-1.0_dp)<1e-14_dp,'disturbed power and spread')

  allocate(input(4096))
  do i=1,size(input)
    input(i)=exp(cmplx(0.0_dp,2*PI*800.0_dp*(i-1)/fs,dp))
  end do
  call fractional_delay(input,12.0_dp,shifted)
  call check(size(shifted)==size(input)+12,'integer-delay length')
  call check(all(abs(shifted(:12))<1e-14_dp),'integer-delay zero prefix')
  call check(maxval(abs(shifted(13:)-input))<1e-14_dp,'integer delay preserves complex samples')
  call check(abs(sum(abs(shifted)**2)/sum(abs(input)**2)-1.0_dp)<1e-14_dp,'integer delay preserves energy')
  call fractional_delay(input,12.5_dp,shifted)
  expected=-2*PI*800.0_dp*12.5_dp/fs
  call check(maxval(abs(shifted(64:4000)-input(64:4000)*exp(cmplx(0.0_dp,expected,dp))))<0.002_dp, &
    'fractional-delay gain and phase at an in-band tone')

  call apply_channel(input,fs,infinity,'awgn',0.0_dp,37.5_dp,0.7_dp,123,.false.,output,variance)
  call check(abs(variance)<tiny(variance),'infinite SNR has no added noise')
  call check(all(abs(output(:123))<1e-14_dp),'arrival offset produces silence')
  measured=0
  do i=1,size(input)
    t=real(i-1,dp)/fs;phase=2*PI*(37.5_dp*t+0.5_dp*0.7_dp*t*t)
    measured=max(measured,abs(output(123+i)-input(i)*exp(cmplx(0.0_dp,phase,dp))))
  end do
  call check(measured<1e-12_dp,'CFO and linear drift use frame-relative time')
  call check(abs(sum(abs(output)**2)/sum(abs(input)**2)-1.0_dp)<1e-12_dp,'CFO and drift preserve energy')

  deallocate(input);allocate(input(180000));input=1
  call seed_rng(643921)
  call apply_channel(input,fs,-18.0_dp,'awgn',0.0_dp,0.0_dp,0.0_dp,6000,.true.,output,variance)
  expected=fs/(2500.0_dp*10.0_dp**(-18.0_dp/10.0_dp))
  call check(abs(variance/expected-1.0_dp)<1e-14_dp,'SNR reference is 2500 Hz')
  measured=sum(abs(output)**2)/size(output)
  call check(abs(measured/expected-1.0_dp)<0.02_dp,'complex noise power equals fs*N0')
  call check(abs(sum(real(output,dp)**2)/size(output)/(expected/2)-1.0_dp)<0.02_dp,'I noise power is fs*N0/2')
  call check(abs(sum(aimag(output)**2)/size(output)/(expected/2)-1.0_dp)<0.02_dp,'Q noise power is fs*N0/2')
  call check(abs(sum(real(output,dp)*aimag(output))/size(output)/expected)<0.01_dp,'I and Q noise are uncorrelated')
  call check(abs(sum(output)/size(output))/sqrt(expected)<0.01_dp,'noise has zero ensemble mean')
  call check(sum(abs(output(:6000))**2)>0.and.sum(abs(output(size(output)-5999:))**2)>0, &
    'noise covers the capture prefix and suffix')
  input=17
  call seed_rng(643921)
  call apply_channel(input,fs,-18.0_dp,'awgn',0.0_dp,0.0_dp,0.0_dp,6000,.true.,repeated,variance)
  call check(maxval(abs(output-repeated))<tiny(variance),'noise-only trials exclude payload and reproduce their seed')

  call seed_rng(817632)
  call frontend_capture(input(:0),fs,0.025_dp,0,180000,output)
  measured=sum(abs(output)**2)/size(output)
  call check(abs(measured/(2400.0_dp*0.025_dp)-1.0_dp)<0.025_dp,'frontend noise power uses its 2400 Hz passband')
  do i=1,size(input)
    input(i)=exp(cmplx(0.0_dp,2*PI*1100.0_dp*(i-1)/fs,dp))
  end do
  call frontend_capture(input,fs,0.0_dp,0,size(input),output)
  call check(maxval(abs(output(10001:170000)-input(10001:170000)))<0.002_dp,'frontend preserves in-band tone amplitude and phase')
  do i=1,size(input)
    input(i)=exp(cmplx(0.0_dp,2*PI*1800.0_dp*(i-1)/fs,dp))
  end do
  call frontend_capture(input,fs,0.0_dp,0,size(input),output)
  call check(maxval(abs(output(10001:170000)))<0.002_dp,'frontend suppresses out-of-band tones')

  call seed_rng(714621)
  call gaussian_fading([0.0_dp,0.1_dp,0.2_dp],0.0_dp,gains)
  call check(maxval(abs(gains-gains(1)))<1e-14_dp,'zero Doppler is constant within a realization')
  mean_gain=0;covariance=0;second_moment=0;fourth_moment=0
  call seed_rng(236951)
  do i=1,8192
    call gaussian_fading([0.0_dp,0.25_dp],1.0_dp,gains)
    mean_gain=mean_gain+gains(1)
    second_moment=second_moment+abs(gains(1))**2
    fourth_moment=fourth_moment+abs(gains(1))**4
    covariance=covariance+gains(2)*conjg(gains(1))
  end do
  mean_gain=mean_gain/8192;second_moment=second_moment/8192
  fourth_moment=fourth_moment/8192;covariance=covariance/8192
  call check(abs(mean_gain)<0.05_dp,'fading has zero ensemble mean')
  call check(abs(second_moment-1.0_dp)<0.06_dp,'fading has unit ensemble power')
  call check(abs(fourth_moment-2.0_dp)<0.18_dp,'fading power is not normalized per realization')
  expected=exp(-PI**2*0.25_dp**2/2)
  call check(abs(covariance-cmplx(expected,0.0_dp,dp))<0.06_dp,'Gaussian Doppler covariance uses spread=2*sigma')
  print '(A,I0,A)','PASS: ',checks,' channel checks'
contains
  subroutine check(condition,message)
    logical,intent(in) :: condition
    character(*),intent(in) :: message
    if(.not.condition) then
      print '(A)','FAIL: '//message
      error stop 1
    end if
    checks=checks+1
  end subroutine check
end program test_channel
