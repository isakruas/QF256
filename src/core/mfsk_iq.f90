! SPDX-License-Identifier: GPL-3.0-or-later
! 256-FSK with QRA coding over GF256.
module mfsk_iq_mod
  use numerics_mod, only: dp,PI
  use qra_soft_mod, only: qra_config,qra_setup,qra_encode,qra_metric,qra_decode
  use v2metrics_mod, only: fft_forward
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
  implicit none
  private
  public :: sc_config,sc_result,setup_sc,sc_tx,sc_rx,sc_peak_reference
  public :: mfsk_statistics,estimate_n0,estimate_tone_n0,estimate_snr_2500,mfsk_filtered_waveform
  real(dp),parameter,public :: blind_cfo_limit_hz=750.0_dp
  type sc_config
    integer :: id=5,nsym=76,ndata=60,npilot=16,n,ns,ntaps,half
    real(dp) :: fs,duration,ts=0.128_dp,spacing=7.8125_dp,lowpass_hz=2000.0_dp
    integer :: data_index(60),pilot_index(16),pilot_tone(16)
    type(qra_config) :: code
  end type sc_config
  type sc_result
    logical :: crc_ok=.false.,used_osd=.false.,snr_valid=.false.
    integer :: payload(77)=0,start=0,iterations=0
    real(dp) :: selected_bd=-1,noise_variance=0,latency_ms=0,cfo=0,evidence=0,snr_2500_db=0
  end type sc_result
contains
  subroutine setup_sc(id,duration,fs,cfg)
    integer,intent(in) :: id
    real(dp),intent(in) :: duration,fs
    type(sc_config),intent(out) :: cfg
    integer :: i,j,state
    if(id/=5)error stop 'MFSK physical profile id must be 5'
    if(duration<=0)error stop 'Duration argument must be positive; physical profile is fixed'
    if(abs(fs/12000.0_dp-nint(fs/12000.0_dp))>1e-9_dp.or.fs<12000) &
      error stop 'Physical MFSK sample rate must be an integer multiple of 12 kHz'
    cfg%id=id;cfg%fs=fs;cfg%ns=nint(cfg%ts*fs);cfg%half=nint(fs*32.0_dp/12000)
    cfg%ntaps=2*cfg%half+1;cfg%n=cfg%nsym*cfg%ns+2*cfg%half
    cfg%duration=real(cfg%n,dp)/fs
    call qra_setup(8,cfg%code)
    state=167
    do i=1,16
      cfg%pilot_index(i)=1+5*(i-1)
      ! Fixed full-period LCG modulo 256 for public pilot tones.
      state=modulo(109*state+89,256);cfg%pilot_tone(i)=state
    end do
    j=0
    do i=1,76
      if(any(cfg%pilot_index==i))cycle
      j=j+1;cfg%data_index(j)=i
    end do
    if(j/=60)error stop 'MFSK pilot/data allocation mismatch'
  end subroutine setup_sc

  subroutine frame_tones(payload,cfg,tones)
    integer,intent(in) :: payload(77)
    type(sc_config),intent(in) :: cfg
    integer,intent(out) :: tones(76)
    integer :: word(65),i
    call qra_encode(payload,cfg%code,word)
    tones(cfg%pilot_index)=cfg%pilot_tone
    do i=1,60
      tones(cfg%data_index(i))=word(cfg%code%transmitted(i))
    end do
  end subroutine frame_tones

  real(dp) function bessel_i0(x) result(value)
    real(dp),intent(in) :: x
    real(dp) :: term
    integer :: i
    term=1;value=1
    do i=1,100
      term=term*(x/(2*i))**2;value=value+term
      if(term<epsilon(value)*value)exit
    end do
  end function bessel_i0

  subroutine mfsk_filtered_waveform(payload,cfg,iq,raw_average)
    ! Exact full discrete FIR convolution, accelerated for piecewise tones.
    ! Each tone contribution uses partial sums of h[r]*exp(-i*w*r).
    ! Full convolution retains the tails of the rectangular burst.
    ! Phase-continuous hops have f*Ts=tone-127.5; boundary phasors alternate +/-1.
    integer,intent(in) :: payload(77)
    type(sc_config),intent(in) :: cfg
    complex(dp),allocatable,intent(out) :: iq(:)
    real(dp),intent(out),optional :: raw_average
    real(dp) :: kernel(0:cfg%ntaps-1),x,w,coordinate
    complex(dp) :: sums(-1:cfg%ntaps-1,0:255),oscillator,rotation,gain
    integer :: tones(76),s,k,m,first,last,idx,tone
    call frame_tones(payload,cfg,tones)
    do k=0,cfg%ntaps-1
      x=real(k-cfg%half,dp)/cfg%fs
      coordinate=real(k-cfg%half,dp)/cfg%half
      if(k==cfg%half)then
        kernel(k)=2*cfg%lowpass_hz/cfg%fs
      else
        kernel(k)=sin(2*PI*cfg%lowpass_hz*x)/(PI*x*cfg%fs)
      end if
      kernel(k)=kernel(k)*bessel_i0(8.6_dp*sqrt(max(0.0_dp,1-coordinate**2)))/bessel_i0(8.6_dp)
    end do
    kernel=kernel/sum(kernel)
    do tone=0,255
      w=2*PI*(tone-127.5_dp)*cfg%spacing/cfg%fs
      rotation=exp(cmplx(0.0_dp,-w,dp));oscillator=1;sums(-1,tone)=0
      do k=0,cfg%ntaps-1
        sums(k,tone)=sums(k-1,tone)+kernel(k)*oscillator
        oscillator=oscillator*rotation
      end do
    end do
    allocate(iq(cfg%n));iq=0
    do s=1,76
      tone=tones(s);w=2*PI*(tone-127.5_dp)*cfg%spacing/cfg%fs
      rotation=exp(cmplx(0.0_dp,w,dp));oscillator=real(1-2*modulo(s-1,2),dp)
      do m=0,cfg%ns+cfg%ntaps-2
        first=max(0,m-cfg%ns+1);last=min(cfg%ntaps-1,m)
        gain=sums(last,tone)-sums(first-1,tone)
        idx=(s-1)*cfg%ns+m+1;iq(idx)=iq(idx)+oscillator*gain
        oscillator=oscillator*rotation
      end do
    end do
    if(present(raw_average))raw_average=sum(abs(iq)**2)/size(iq)
  end subroutine mfsk_filtered_waveform

  subroutine sc_tx(payload,cfg,iq)
    integer,intent(in) :: payload(77)
    type(sc_config),intent(in) :: cfg
    complex(dp),allocatable,intent(out) :: iq(:)
    real(dp) :: average
    call mfsk_filtered_waveform(payload,cfg,iq,average)
    iq=iq/sqrt(average)
  end subroutine sc_tx

  subroutine sc_peak_reference(payload,cfg,peak_reference,convergence_db)
    ! Regenerate the continuous-phase source and finite kernel at 48/192 kHz.
    ! Normalize both powers by the 12 kHz TX average.
    integer,intent(in) :: payload(77)
    type(sc_config),intent(in) :: cfg
    real(dp),intent(out) :: peak_reference,convergence_db
    type(sc_config) :: sampled
    complex(dp),allocatable :: wave(:)
    real(dp) :: average,peak48,peak192
    call mfsk_filtered_waveform(payload,cfg,wave,average)
    call setup_sc(5,cfg%duration,48000.0_dp,sampled)
    sampled%lowpass_hz=cfg%lowpass_hz
    call mfsk_filtered_waveform(payload,sampled,wave);peak48=maxval(abs(wave)**2)/average
    call setup_sc(5,cfg%duration,192000.0_dp,sampled)
    sampled%lowpass_hz=cfg%lowpass_hz
    call mfsk_filtered_waveform(payload,sampled,wave);peak192=maxval(abs(wave)**2)/average
    convergence_db=abs(10*log10(peak192/peak48))
    if(convergence_db>0.05_dp)error stop 'MFSK TX peak requires sampling finer than192k'
    peak_reference=max(peak48,peak192)
  end subroutine sc_peak_reference

  real(dp) function estimate_n0(iq,fs) result(noise)
    ! Hann-windowed 512-point spectra; guards at 2500..5000 Hz on both sides.
    ! Window-energy normalization preserves complex N0.
    complex(dp),intent(in) :: iq(:)
    real(dp),intent(in) :: fs
    complex(dp) :: block(512)
    real(dp) :: window(512),window_energy,power
    integer :: i,j,k,blocks,first_bin,last_bin,count
    do i=1,512
      window(i)=0.5_dp-0.5_dp*cos(2*PI*(i-1)/512.0_dp)
    end do
    window_energy=sum(window**2);blocks=size(iq)/512
    first_bin=ceiling(2500.0_dp*512/fs);last_bin=min(255,floor(5000.0_dp*512/fs))
    if(blocks<1.or.first_bin>last_bin)error stop 'Capture too short or invalid rate for noise guards'
    power=0;count=0
    do j=0,blocks-1
      block=iq(512*j+1:512*j+512)*window;call fft_forward(block)
      do k=first_bin,last_bin
        power=power+abs(block(k+1))**2+abs(block(513-k))**2;count=count+2
      end do
    end do
    noise=max(power/(count*window_energy*fs),1.0e-20_dp)
  end function estimate_n0

  real(dp) function estimate_tone_n0(energy) result(noise)
    ! A channel may remove the public out-of-band noise guards while leaving
    ! the 256-FSK tones intact.  In each data symbol only one of the 256
    ! orthogonal projections carries signal, so the middle two order
    ! statistics provide a robust in-band noise estimate.  The normalization
    ! is the exact expected mean of those two order statistics for 256
    ! unit-mean exponential samples.
    real(dp),intent(in) :: energy(0:255,60)
    real(dp),parameter :: median_expectation=0.6951041202281072_dp
    real(dp) :: ordered(256),value,total
    integer :: symbol,i,j
    total=0
    do symbol=1,60
      ordered=energy(:,symbol)
      do i=2,256
        value=ordered(i);j=i-1
        do while(j>=1)
          if(ordered(j)<=value)exit
          ordered(j+1)=ordered(j);j=j-1
        end do
        ordered(j+1)=value
      end do
      total=total+.5_dp*(ordered(128)+ordered(129))/median_expectation
    end do
    noise=max(total/60.0_dp,1.0e-20_dp)
  end function estimate_tone_n0

  subroutine search_sync(iq,cfg,smin,smax,sstep,fmin,fmax,fstep,start,cfo,score)
    ! Rolling complex sums evaluate all trial starts with only one tone mixing
    ! pass per public pilot and CFO.
    complex(dp),intent(in) :: iq(:)
    type(sc_config),intent(in) :: cfg
    integer,intent(in) :: smin,smax,sstep
    real(dp),intent(in) :: fmin,fmax,fstep
    integer,intent(out) :: start
    real(dp),intent(out) :: cfo,score
    complex(dp),allocatable :: prefix(:)
    real(dp),allocatable :: scores(:)
    complex(dp) :: osc,rot,total
    real(dp) :: freq,carrier,value
    integer :: nf,nt,fi,p,m,idx,base,length,t
    nt=(smax-smin)/sstep+1;nf=nint((fmax-fmin)/fstep)+1
    length=smax-smin+cfg%ns;allocate(prefix(0:length),scores(nt))
    score=-huge(1.0_dp);start=smin;cfo=fmin
    do fi=0,nf-1
      carrier=fmin+fi*fstep;scores=0
      do p=1,16
        freq=(cfg%pilot_tone(p)-127.5_dp)*cfg%spacing+carrier
        rot=exp(cmplx(0.0_dp,-2*PI*freq/cfg%fs,dp));osc=1;prefix(0)=0
        base=smin+cfg%half+(cfg%pilot_index(p)-1)*cfg%ns
        do m=1,length
          idx=base+m
          if(idx>=1.and.idx<=size(iq))then
            prefix(m)=prefix(m-1)+iq(idx)*osc
          else
            prefix(m)=prefix(m-1)
          end if
          osc=osc*rot
        end do
        do t=1,nt
          m=(t-1)*sstep;total=prefix(m+cfg%ns)-prefix(m)
          scores(t)=scores(t)+abs(total)**2
        end do
      end do
      t=maxloc(scores,dim=1);value=scores(t)
      if(value>score)then
        score=value;start=smin+(t-1)*sstep;cfo=carrier
      end if
    end do
    score=score/(cfg%fs*cfg%ns)
  end subroutine search_sync

  subroutine acquire(iq,cfg,start,cfo,score)
    complex(dp),intent(in) :: iq(:)
    type(sc_config),intent(in) :: cfg
    integer,intent(out) :: start
    real(dp),intent(out) :: cfo,score
    integer :: coarse_start,refined_start,lo,hi
    real(dp) :: coarse_cfo,refined_cfo,lowfreq,highfreq,coarse_step,middle_step,fine_step
    lo=nint(.3_dp*cfg%fs);hi=nint(.7_dp*cfg%fs)
    ! Search a fixed complex-baseband interval, independent of RF tuning.
    ! A tone-spacing/2 first grid bounds coherent loss, then two local grids
    ! recover the original final frequency and timing resolution without
    ! evaluating every fine hypothesis across the complete interval.
    coarse_step=cfg%spacing/2
    middle_step=cfg%spacing/32
    fine_step=cfg%spacing/320
    call search_sync(iq,cfg,lo,hi,cfg%ns/16,-blind_cfo_limit_hz,blind_cfo_limit_hz, &
      coarse_step,coarse_start,coarse_cfo,score)
    lowfreq=max(-blind_cfo_limit_hz,coarse_cfo-coarse_step)
    highfreq=min(blind_cfo_limit_hz,coarse_cfo+coarse_step)
    call search_sync(iq,cfg,max(lo,coarse_start-cfg%ns/16),min(hi,coarse_start+cfg%ns/16), &
      max(1,cfg%ns/96),lowfreq,highfreq,middle_step,refined_start,refined_cfo,score)
    lowfreq=max(-blind_cfo_limit_hz,refined_cfo-middle_step)
    highfreq=min(blind_cfo_limit_hz,refined_cfo+middle_step)
    call search_sync(iq,cfg,max(lo,refined_start-cfg%ns/96),min(hi,refined_start+cfg%ns/96), &
      max(1,cfg%ns/384),lowfreq,highfreq,fine_step,start,cfo,score)
  end subroutine acquire

  subroutine mfsk_statistics(iq,cfg,start,cfo,energy)
    ! Unit-energy tone projections: complex-noise variance is N0, because
    ! sum(IQ*exp(-iwt))/sqrt(fs*Ns) has variance(fs*N0)*Ns/(fs*Ns).
    ! A 1536=3*512 mixed-radix FFT evaluates the 256 tone bins.
    complex(dp),intent(in) :: iq(:)
    type(sc_config),intent(in) :: cfg
    integer,intent(in) :: start
    real(dp),intent(in) :: cfo
    real(dp),intent(out) :: energy(0:255,60)
    complex(dp) :: lanes(512,0:2),osc,rot,value,twiddle(0:255,0:2)
    integer :: symbol,j,k,r,m,idx,base,bin
    if(cfg%ns/=1536)error stop 'MFSK RX requires12kHz/1536 samples per symbol'
    do k=0,255
      do r=0,2
        twiddle(k,r)=exp(cmplx(0.0_dp,-2*PI*(k-128)*r/real(cfg%ns,dp),dp))
      end do
    end do
    rot=exp(cmplx(0.0_dp,-2*PI*(cfo+cfg%spacing/2)/cfg%fs,dp))
    do symbol=1,60
      base=start+cfg%half+(cfg%data_index(symbol)-1)*cfg%ns;osc=1
      do j=0,cfg%ns-1
        r=modulo(j,3);m=j/3+1;idx=base+j+1
        lanes(m,r)=0
        if(idx>=1.and.idx<=size(iq))lanes(m,r)=iq(idx)*osc
        osc=osc*rot
      end do
      do r=0,2
        call fft_forward(lanes(:,r))
      end do
      do k=0,255
        bin=modulo(k-128,512)+1;value=0
        do r=0,2
          value=value+twiddle(k,r)*lanes(bin,r)
        end do
        energy(k,symbol)=abs(value)**2/(cfg%fs*cfg%ns)
      end do
    end do
  end subroutine mfsk_statistics

  subroutine estimate_snr_2500(payload,cfg,received_energy,n0,snr_db,valid)
    ! Estimate received active-frame signal power from the decoded data tones.
    ! Each correct-bin projection has expectation P*g_j + N0. The matching
    ! clean, unit-average-power frame supplies sum(g_j), including the exact
    ! transmit filter and tone-transition losses for this payload. Subtracting
    ! one N0 per data symbol therefore gives an unbiased AWGN power estimate.
    integer,intent(in) :: payload(77)
    type(sc_config),intent(in) :: cfg
    real(dp),intent(in) :: received_energy(0:255,60),n0
    real(dp),intent(out) :: snr_db
    logical,intent(out) :: valid
    complex(dp),allocatable :: reference_iq(:)
    real(dp),allocatable :: reference_energy(:,:)
    real(dp) :: signal_sum,reference_sum,power_estimate
    integer :: tones(76),i,tone
    snr_db=0;valid=.false.
    if(.not.ieee_is_finite(n0).or.n0<=0) return
    call frame_tones(payload,cfg,tones)
    call sc_tx(payload,cfg,reference_iq)
    allocate(reference_energy(0:255,60))
    call mfsk_statistics(reference_iq,cfg,0,0.0_dp,reference_energy)
    signal_sum=0;reference_sum=0
    do i=1,60
      tone=tones(cfg%data_index(i))
      signal_sum=signal_sum+received_energy(tone,i)-n0
      reference_sum=reference_sum+reference_energy(tone,i)
    end do
    if(.not.ieee_is_finite(signal_sum).or..not.ieee_is_finite(reference_sum)) return
    if(signal_sum<=0.or.reference_sum<=0) return
    power_estimate=signal_sum/reference_sum
    if(.not.ieee_is_finite(power_estimate).or.power_estimate<=0) return
    snr_db=10*log10(power_estimate/(2500.0_dp*n0))
    valid=ieee_is_finite(snr_db)
    if(.not.valid) snr_db=0
  end subroutine estimate_snr_2500

  subroutine sc_rx(iq,cfg,sync,result)
    complex(dp),intent(in) :: iq(:)
    type(sc_config),intent(in) :: cfg
    character(*),intent(in) :: sync
    type(sc_result),intent(out) :: result
    real(dp),allocatable :: energy(:,:),probability(:,:)
    real(dp) :: n0,guard_n0,tone_n0,score,t0,t1
    call cpu_time(t0);result=sc_result();guard_n0=estimate_n0(iq,cfg%fs)
    allocate(energy(0:255,60),probability(0:255,60))
    if(sync=='blind')then
      call acquire(iq,cfg,result%start,result%cfo,score)
    else if(sync=='known')then
      call search_sync(iq,cfg,0,0,1,0.0_dp,0.0_dp,1.0_dp,result%start,result%cfo,score)
    else
      error stop 'MFSK synchronization must be known or blind'
    end if
    call mfsk_statistics(iq,cfg,result%start,result%cfo,energy)
    tone_n0=estimate_tone_n0(energy);n0=guard_n0
    ! Preserve the calibrated guard estimate when those bands are present.
    ! If a receiver passband has suppressed them by more than 3 dB, use the
    ! robust in-band estimate instead of feeding near-zero N0 to the decoder.
    if(guard_n0<.5_dp*tone_n0)n0=tone_n0
    call qra_metric(energy,n0,probability)
    call qra_decode(probability,cfg%code,result%payload,result%crc_ok,result%iterations,max_iterations=100)
    result%noise_variance=cfg%fs*n0;result%evidence=score/n0-16
    if(result%crc_ok) call estimate_snr_2500(result%payload,cfg,energy,n0,result%snr_2500_db,result%snr_valid)
    call cpu_time(t1);result%latency_ms=1000*(t1-t0)
  end subroutine sc_rx
end module mfsk_iq_mod
