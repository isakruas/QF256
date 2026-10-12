! SPDX-License-Identifier: GPL-3.0-or-later
! Fixed-seed validation of the public 2500 Hz SNR estimate.
program validate_snr
  use iso_fortran_env, only: int64
  use, intrinsic :: ieee_arithmetic, only: ieee_value,ieee_positive_inf
  use numerics_mod, only: dp,seed_rng
  use mfsk_iq_mod, only: sc_config,sc_result,setup_sc,sc_tx,mfsk_statistics,estimate_n0,estimate_tone_n0,estimate_snr_2500
  use qf256_api, only: qf256_decode,qf256_ok
  use channel_mod, only: apply_channel
  use study_frontend_mod, only: frontend_capture
  implicit none
  type(sc_config) :: cfg
  type(sc_result) :: result
  integer :: payload(77),i,level,trial,decoded,selected,ios
  integer(int64) :: state
  real(dp) :: target,n0,n0_est,snr_est,error_sum,error_sq,noise_variance,tone_n0,infinity
  real(dp) :: received_energy(0:255,60)
  complex(dp),allocatable :: tx(:),rx(:),clean(:)
  character(16) :: profile
  character(32) :: argument
  logical :: valid,accepted

  call setup_sc(5,10.0_dp,12000.0_dp,cfg)
  selected=0
  if(command_argument_count()>0)then
    call get_command_argument(1,argument);read(argument,*,iostat=ios)selected
    if(ios/=0.or.selected<1.or.selected>15) error stop 'Expected validation row index 1..15'
  end if
  infinity=ieee_value(0.0_dp,ieee_positive_inf)
  state=783271_int64
  do i=1,77
    state=modulo(16807_int64*state,2147483647_int64)
    payload(i)=merge(1,0,state>1073741823_int64)
  end do
  call sc_tx(payload,cfg,tx)

  print '(A)','channel,target_snr_db,valid_cases,bias_db,rmse_db'
  do level=1,6
    if(selected/=0.and.selected/=level)cycle
    target=-26.0_dp+2.0_dp*level
    n0=1.0_dp/(2500.0_dp*10.0_dp**(target/10.0_dp))
    error_sum=0;error_sq=0
    do trial=1,128
      call seed_rng(70701011+1000*level+trial)
      call frontend_capture(tx,cfg%fs,n0,0,size(tx),rx)
      call mfsk_statistics(rx,cfg,0,0.0_dp,received_energy)
      n0_est=estimate_n0(rx,cfg%fs)
      tone_n0=estimate_tone_n0(received_energy)
      if(n0_est<.5_dp*tone_n0)n0_est=tone_n0
      call estimate_snr_2500(payload,cfg,received_energy,n0_est,snr_est,valid)
      if(.not.valid) error stop 'AWGN SNR estimate unexpectedly invalid'
      error_sum=error_sum+snr_est-target;error_sq=error_sq+(snr_est-target)**2
      deallocate(rx)
    end do
    print '(A,F0.1,A,I0,A,F0.4,A,F0.4)','awgn,',target,',',128,',',error_sum/128,',',sqrt(error_sq/128)
  end do

  do level=1,9
    if(selected/=0.and.selected/=level+6)cycle
    select case((level-1)/3)
    case(0); profile='quiet'
    case(1); profile='moderate'
    case(2); profile='disturbed'
    end select
    target=-18.0_dp+2.0_dp*modulo(level-1,3)
    error_sum=0;error_sq=0;decoded=0
    do trial=1,128
      call seed_rng(80701011+10000*level+trial)
      call apply_channel(tx,cfg%fs,infinity,trim(profile),-1.0_dp,3.2_dp,0.0_dp,0,.false.,clean,noise_variance)
      call seed_rng(90701011+10000*level+trial)
      n0=1.0_dp/(2500.0_dp*10.0_dp**(target/10.0_dp))
      call frontend_capture(clean,cfg%fs,n0,6000,180000,rx)
      call qf256_decode(rx,'blind',result,accepted,ios)
      if(ios/=qf256_ok)error stop 'Public decoder rejected SNR validation capture'
      if(accepted.and.all(result%payload==payload))then
        if(.not.result%snr_valid) error stop 'CRC-valid fading decode lacks SNR estimate'
        error_sum=error_sum+result%snr_2500_db-target
        error_sq=error_sq+(result%snr_2500_db-target)**2
        decoded=decoded+1
      end if
      deallocate(rx)
    end do
    if(decoded<=0) error stop 'SNR validation profile has no valid decodes'
    print '(A,A,F0.1,A,I0,A,F0.4,A,F0.4)',trim(profile),',',target,',',decoded,',', &
      error_sum/decoded,',',sqrt(error_sq/decoded)
  end do
end program validate_snr
