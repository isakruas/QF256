! SPDX-License-Identifier: GPL-3.0-or-later
! Reproduce one registered trial; no batch is started implicitly.
program reproduce_trial
  use, intrinsic :: ieee_arithmetic, only: ieee_value, ieee_positive_inf
  use numerics_mod, only: dp, seed_rng, rng_uniform, rng_normal
  use channel_mod, only: apply_channel
  use mfsk_iq_mod, only: sc_config, sc_result, setup_sc, sc_tx, sc_rx, sc_peak_reference
  use v2metrics_mod, only: waveform_metrics
  implicit none
  real(dp), parameter :: fs=12000.0_dp, gate=22.644583913858970_dp
  real(dp), parameter :: snrs(6)=[-24.0_dp,-22.0_dp,-20.0_dp,-18.0_dp,-16.0_dp,-14.0_dp]
  character(4096) :: argument, output_path
  character(16) :: phase, constraint, profile
  character(18) :: source_hex
  integer :: channel_id, point, trial, condition, pseed, cseed, nseed, base, index, maximum
  integer :: payload(77), offset, i, unit, status
  real(dp) :: snr, average, peak, energy, papr, bandwidth, convergence, peak_reference
  real(dp) :: start_s, cfo, variance, infinity, mean_snr, eb77, eb71
  logical :: accepted, correct, calibration
  complex(dp), allocatable :: iq(:), clean(:), capture(:)
  type(sc_config) :: cfg
  type(sc_result) :: result

  if(command_argument_count()<1) call usage()
  call get_command_argument(1,phase)
  call setup_sc(5,10.0_dp,fs,cfg)
  allocate(capture(180000))
  select case(trim(phase))
  case('signal')
    if(command_argument_count()/=6) call usage()
    call get_command_argument(2,argument); read(argument,*,iostat=status) channel_id
    if(status/=0) call usage()
    if(channel_id/=3.and.channel_id/=4) call usage()
    call get_command_argument(3,constraint)
    if(constraint/='average'.and.constraint/='peak') call usage()
    call get_command_argument(4,argument); read(argument,*,iostat=status) point
    if(status/=0) call usage()
    call get_command_argument(5,argument); read(argument,*,iostat=status) trial
    if(status/=0) call usage()
    if(point<1.or.point>6.or.trial<1.or.trial>128) call usage()
    call get_command_argument(6,output_path)
    call open_output()
    profile='moderate'; if(channel_id==4) profile='hard'
    snr=snrs(point); condition=(channel_id-1)*6+point; base=20261201
    pseed=base+condition*100003+trial*101
    cseed=base+condition*200003+trial*307
    nseed=base+condition*300007+trial*911
    call seed_rng(pseed)
    call study_payload(payload,source_hex)
    start_s=.5_dp+.2_dp*(rng_uniform()-.5_dp)
    cfo=4*(rng_uniform()-.5_dp)
    call sc_tx(payload,cfg,iq)
    call waveform_metrics(iq,fs,papr,bandwidth,energy,peak,average)
    call sc_peak_reference(payload,cfg,peak_reference,convergence)
    peak=peak_reference; papr=10*log10(peak/average)
    if(constraint=='peak') then
      iq=iq/sqrt(peak); energy=energy/peak; average=average/peak; peak=1
    end if
    mean_snr=snr+10*log10(average)
    eb77=snr+10*log10(2500*energy/77)
    eb71=snr+10*log10(2500*energy/71)
    infinity=ieee_value(0.0_dp,ieee_positive_inf)
    call seed_rng(cseed)
    call apply_channel(iq,fs,infinity,trim(profile),-1.0_dp,cfo,0.0_dp,0,.false.,clean,variance)
    capture=0; offset=nint(start_s*fs)
    capture(offset+1:offset+size(clean))=clean
    call seed_rng(nseed+29)
    variance=fs/(2500*10.0_dp**(snr/10))
    do i=1,size(capture)
      capture(i)=capture(i)+sqrt(variance/2)*cmplx(rng_normal(),rng_normal(),dp)
    end do
    ! Only received IQ and the public configuration enter the receiver.
    call sc_rx(capture,cfg,'blind',result)
    accepted=result%crc_ok.and.result%evidence>=gate
    correct=accepted.and.all(result%payload==payload)
    write(unit,'(A)') 'channel_id,constraint,snr_db,trial,payload_seed,channel_seed,noise_seed,'// &
      'source71_hex,accepted,correct_payload,decoded_wrong,average_power,peak_power,energy,'// &
      'papr_db,bw99_hz,snr_average_db,ebn0_77_db,ebn0_71_db,start_true_s,start_estimated_s,'// &
      'cfo_true_hz,cfo_estimated_hz,iterations,evidence,peak_convergence_db'
    write(unit,'(*(G0,:,","))') channel_id,trim(constraint),snr,trial,pseed,cseed,nseed,source_hex, &
      merge(1,0,accepted),merge(1,0,correct),merge(1,0,accepted.and..not.correct),average,peak, &
      energy,papr,bandwidth,mean_snr,eb77,eb71,start_s,result%start/fs,cfo,result%cfo, &
      result%iterations,result%evidence,convergence
  case('noise-cal','noise-check')
    if(command_argument_count()/=3) call usage()
    call get_command_argument(2,argument); read(argument,*,iostat=status) index
    if(status/=0) call usage()
    call get_command_argument(3,output_path)
    calibration=phase=='noise-cal'
    base=20263501; maximum=4096
    if(calibration) then
      base=20263401; maximum=2048
    end if
    if(index<1.or.index>maximum) call usage()
    call open_output()
    point=modulo(index-1,6)+1; trial=(index-1)/6+1
    nseed=base+point*300007+trial*911+29; snr=snrs(point)
    variance=fs/(2500*10.0_dp**(snr/10))
    call seed_rng(nseed)
    do i=1,size(capture)
      capture(i)=sqrt(variance/2)*cmplx(rng_normal(),rng_normal(),dp)
    end do
    call sc_rx(capture,cfg,'blind',result)
    accepted=result%crc_ok
    if(.not.calibration) accepted=accepted.and.result%evidence>=gate
    write(unit,'(A)') 'phase,global_index,point,trial,snr_reference_db,actual_noise_seed,'// &
      'raw_crc_accepted,accepted,evidence,true_noise_variance,estimated_noise_variance,'// &
      'start_estimated_s,cfo_estimated_hz,iterations,gate_enabled,gate'
    write(unit,'(*(G0,:,","))') trim(phase),index,point,trial,snr,nseed,merge(1,0,result%crc_ok), &
      merge(1,0,accepted),result%evidence,variance,result%noise_variance,result%start/fs,result%cfo, &
      result%iterations,merge(0,1,calibration),merge(0.0_dp,gate,calibration)
  case default
    call usage()
  end select
  close(unit)
contains
  subroutine open_output()
    open(newunit=unit,file=trim(output_path),status='new',action='write',iostat=status)
    if(status/=0) error stop 'Output must be a new writable file in an existing directory'
  end subroutine open_output

  subroutine study_payload(bits,hex)
    ! Preserve the original 18 uniform draws and MSB-first bit packing.
    integer, intent(out) :: bits(77)
    character(18), intent(out) :: hex
    character(*), parameter :: digits='0123456789ABCDEF'
    integer :: j,k,value,width,position
    position=0
    do j=1,18
      width=4
      if(j==1) width=3
      value=int(real(2**width,dp)*rng_uniform())
      hex(j:j)=digits(value+1:value+1)
      do k=width-1,0,-1
        position=position+1; bits(position)=ibits(value,k,1)
      end do
    end do
    bits(72:77)=[1,0,1,0,0,0]
  end subroutine study_payload

  subroutine usage()
    print '(A)', 'reproduce signal CHANNEL(3|4) average|peak POINT(1..6) TRIAL(1..128) OUTPUT.csv'
    print '(A)', 'reproduce noise-cal INDEX(1..2048) OUTPUT.csv'
    print '(A)', 'reproduce noise-check INDEX(1..4096) OUTPUT.csv'
    error stop 2
  end subroutine usage
end program reproduce_trial
