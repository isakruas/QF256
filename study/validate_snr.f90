! SPDX-License-Identifier: GPL-3.0-or-later
! Fixed-seed validation of the public 2500 Hz SNR estimate.
program validate_snr
  use iso_fortran_env, only: int64
  use numerics_mod, only: dp,seed_rng,rng_normal
  use mfsk_iq_mod, only: sc_config,sc_result,setup_sc,sc_tx,sc_rx,mfsk_statistics,estimate_n0,estimate_snr_2500
  use channel_mod, only: apply_channel
  implicit none
  type(sc_config) :: cfg
  type(sc_result) :: result
  integer :: payload(77),i,level,trial,decoded
  integer(int64) :: state
  real(dp) :: target,n0,n0_est,snr_est,error_sum,error_sq,noise_variance
  real(dp) :: received_energy(0:255,60)
  complex(dp),allocatable :: tx(:),rx(:)
  character(8) :: profile
  logical :: valid

  call setup_sc(5,10.0_dp,12000.0_dp,cfg)
  state=783271_int64
  do i=1,77
    state=modulo(16807_int64*state,2147483647_int64)
    payload(i)=merge(1,0,state>1073741823_int64)
  end do
  call sc_tx(payload,cfg,tx)

  print '(A)','channel,target_snr_db,valid_cases,bias_db,rmse_db'
  do level=1,6
    target=-26.0_dp+2.0_dp*level
    n0=1.0_dp/(2500.0_dp*10.0_dp**(target/10.0_dp))
    error_sum=0;error_sq=0
    do trial=1,128
      allocate(rx(size(tx)));call seed_rng(700000+1000*level+trial)
      do i=1,size(tx)
        rx(i)=tx(i)+sqrt(cfg%fs*n0/2)*cmplx(rng_normal(),rng_normal(),dp)
      end do
      call mfsk_statistics(rx,cfg,0,0.0_dp,received_energy)
      n0_est=estimate_n0(rx,cfg%fs)
      call estimate_snr_2500(payload,cfg,received_energy,n0_est,snr_est,valid)
      if(.not.valid) error stop 'AWGN SNR estimate unexpectedly invalid'
      error_sum=error_sum+snr_est-target;error_sq=error_sq+(snr_est-target)**2
      deallocate(rx)
    end do
    print '(A,F0.1,A,I0,A,F0.4,A,F0.4)','awgn,',target,',',128,',',error_sum/128,',',sqrt(error_sq/128)
  end do

  do level=1,6
    if(level<=3)then
      profile='moderate';target=-18.0_dp+2.0_dp*(level-1)
    else
      profile='hard';target=-18.0_dp+2.0_dp*(level-4)
    end if
    error_sum=0;error_sq=0;decoded=0
    do trial=1,128
      call seed_rng(810000+10000*level+trial)
      call apply_channel(tx,cfg%fs,target,trim(profile),-1.0_dp,3.2_dp,0.0_dp,6000,.false.,rx,noise_variance)
      call sc_rx(rx,cfg,'blind',result)
      if(result%crc_ok.and.all(result%payload==payload))then
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
