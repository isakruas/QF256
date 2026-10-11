program test_core
  use iso_fortran_env, only: real32,int16,int64
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
  use numerics_mod, only: dp,PI,seed_rng,rng_normal
  use qra_soft_mod, only: qra_encode,qra_decode,qra_syndrome
  use mfsk_iq_mod, only: sc_config,sc_result,setup_sc,sc_tx,sc_rx,sc_peak_reference,mfsk_statistics, &
    estimate_n0,blind_cfo_limit_hz
  use v2metrics_mod, only: waveform_metrics
  implicit none
  type(sc_config) :: cfg
  type(sc_result) :: result
  integer :: payload(77),fixture_bits(77),decoded(77),word(65),expected(65),i,j,n,u,ios,index,trial,iterations,checks
  integer :: offset,wrong,rc
  integer(int16), allocatable :: pcm(:)
  integer(int64) :: state
  real(dp) :: probability(0:255,60),xr,xi,phase,gain,cfo,energy,peak,avg,papr,bw,peak_reference,convergence
  real(dp) :: audio_peak,audio_gain,pcm_error,n0,guard_mean,bin_mean,energies(0:255,60),target_snr
  real(dp),parameter :: blind_cfos(9)=[-750.0_dp,-748.046875_dp,-160.375_dp,-40.25_dp,0.0_dp, &
    40.625_dp,160.25_dp,748.046875_dp,750.0_dp]
  integer,parameter :: boundary_starts(4)=[3600,3600,8400,8400]
  real(dp),parameter :: boundary_cfos(4)=[-750.0_dp,750.0_dp,-750.0_dp,750.0_dp]
  real(real32), allocatable :: packed(:,:)
  complex(dp), allocatable :: iq(:),capture(:),minimum_capture(:),noise(:),wide_noise(:),filtered_noise(:)
  logical :: ok
  character(77) :: text
  character(44) :: header
  checks=0
  call execute_command_line('mkdir -p build/test',exitstat=rc)
  if(rc/=0) error stop 'Cannot create test scratch directory'
  call setup_sc(5,10.0_dp,12000.0_dp,cfg)
  call check(cfg%n==116800.and.cfg%ns==1536,'frame sample and symbol lengths')
  call check(blind_cfo_limit_hz==750.0_dp,'fixed blind CFO acquisition limit')
  call check(cfg%ndata==60.and.cfg%npilot==16.and.cfg%nsym==76,'data and pilot schedule')
  call check(abs(cfg%duration-9.733333333333333_dp)<1e-12_dp,'full filtered duration')
  call check(all(cfg%pilot_tone==[116,189,210,195,96,57,158,159,12,117,42,59,120,113,118,151]),'fixed public pilot tones')
  open(newunit=u,file='tests/fixtures/payload77.txt',status='old')
  read(u,'(A)') text; close(u)
  do i=1,77
    fixture_bits(i)=iachar(text(i:i))-iachar('0')
  end do
  call check(all(fixture_bits==0.or.fixture_bits==1),'fixture payload is binary')
  open(newunit=u,file='tests/fixtures/codeword65.txt',status='old')
  read(u,*) expected; close(u)
  call qra_encode(fixture_bits,cfg%code,word)
  call check(all(word==expected),'all 65 encoded symbols match fixed fixture')
  call check(qra_syndrome(word,cfg%code)==0,'fixture satisfies every parity check')
  call check(all(word(11:13)==0).and.iand(word(10),7)==0,'shortening and public pad bits')
  call sc_tx(fixture_bits,cfg,iq)
  open(newunit=u,file='tests/fixtures/iq_subset.txt',status='old')
  read(u,*) n
  do j=1,n
    read(u,*,iostat=ios) index,xr,xi
    if(ios/=0.or.index<1.or.index>size(iq)) error stop 'Invalid IQ subset fixture'
    call check(abs(iq(index)-cmplx(xr,xi,dp))<2e-10_dp,'IQ sample matches frozen subset')
  end do
  close(u)
  allocate(packed(2,size(iq))); packed(1,:)=real(iq,real32); packed(2,:)=real(aimag(iq),real32)
  open(newunit=u,file='build/test/core_fixture.cf32',access='stream',form='unformatted',status='replace')
  write(u) packed; close(u)
  call execute_command_line('sha256sum -c tests/fixtures/iq_f32.sha256 > build/test/iq_hash.log',exitstat=rc)
  call check(rc==0,'full interleaved float32 IQ hash')
  ! Full audio fixture is an independently preserved export, never rebuilt by tests.
  allocate(pcm(cfg%n))
  open(newunit=u,file='tests/fixtures/reference_audio.wav',access='stream',form='unformatted',status='old')
  read(u) header; read(u) pcm; close(u)
  call check(header(1:4)=='RIFF'.and.header(9:12)=='WAVE','reference audio container')
  audio_peak=0
  do i=1,size(iq)
    phase=2*PI*1500.0_dp*real(i-1,dp)/cfg%fs
    audio_peak=max(audio_peak,abs(sqrt(2.0_dp)*real(iq(i)*exp(cmplx(0.0_dp,phase,dp)),dp)))
  end do
  audio_gain=10.0_dp**(-3.0_dp/20)/audio_peak; pcm_error=0
  do i=1,size(iq)
    phase=2*PI*1500.0_dp*real(i-1,dp)/cfg%fs
    j=nint(32767*audio_gain*sqrt(2.0_dp)*real(iq(i)*exp(cmplx(0.0_dp,phase,dp)),dp))
    pcm_error=max(pcm_error,real(abs(j-int(pcm(i))),dp))
  end do
  call check(pcm_error<.5_dp,'all reference PCM samples match the preserved export')
  call waveform_metrics(iq,cfg%fs,papr,bw,energy,peak,avg)
  call check(abs(avg-1)<1e-11_dp.and.abs(energy-cfg%duration)<1e-9_dp,'complete filtered energy and mean power')
  call check(bw>1500.0_dp.and.bw<2000.0_dp,'occupied bandwidth physical range')
  call sc_peak_reference(fixture_bits,cfg,peak_reference,convergence)
  call check(convergence<=.05_dp,'48/192 kHz peak convergence')
  call check(peak<=peak_reference*10.0_dp**(.01_dp/10),'reconstructed peak covers 12 kHz samples')
  state=715501_int64
  do trial=1,4
    payload=fixture_bits
    if(trial==2) payload=0
    if(trial==3) payload=1
    if(trial==4) call random_payload(payload)
    call qra_encode(payload,cfg%code,word)
    probability=1e-9_dp
    do i=1,60
      probability(word(cfg%code%transmitted(i)),i)=1
    end do
    call qra_decode(probability,cfg%code,decoded,ok,iterations)
    call check(ok.and.all(decoded==payload),'GF256 soft decoder roundtrip')
    do j=1,6
      i=modulo((j-1)*7+trial,60)+1; index=word(cfg%code%transmitted(i))
      probability(index,i)=.7_dp; probability(modulo(index+1,256),i)=1
    end do
    wrong=0
    do i=1,60
      if(maxloc(probability(:,i),dim=1)-1/=word(cfg%code%transmitted(i))) wrong=wrong+1
    end do
    call check(wrong==6,'six deliberately incorrect hard-symbol decisions')
    call qra_decode(probability,cfg%code,decoded,ok,iterations)
    call check(ok.and.all(decoded==payload),'soft decoder corrects the six symbol errors')
    call sc_tx(payload,cfg,iq)
    phase=.37_dp*trial; gain=.4_dp+.3_dp*trial
    call sc_rx(gain*exp(cmplx(0.0_dp,phase,dp))*iq,cfg,'known',result)
    call check(result%crc_ok.and.all(result%payload==payload),'known-boundary modem roundtrip with gain and phase')
    call check(result%evidence>=30.22075_dp,'clean frame passes public evidence gate')
    call check(result%snr_valid.and.ieee_is_finite(result%snr_2500_db),'CRC-valid frame has a finite SNR estimate')
  end do
  target_snr=-16.0_dp;n0=1.0_dp/(2500.0_dp*10.0_dp**(target_snr/10.0_dp))
  allocate(noise(size(iq)));call seed_rng(705001)
  do i=1,size(noise)
    noise(i)=sqrt(cfg%fs*n0/2)*cmplx(rng_normal(),rng_normal(),dp)
  end do
  call sc_rx(iq+noise,cfg,'known',result)
  call check(result%crc_ok.and.result%snr_valid,'AWGN SNR test frame decodes with a valid estimate')
  call check(abs(result%snr_2500_db-target_snr)<1.5_dp,'AWGN SNR estimate is within 1.5 dB of the known value')
  probability=1.0_dp/256
  call qra_decode(probability,cfg%code,decoded,ok,iterations)
  call check(.not.ok,'uninformative soft input is rejected')
  allocate(capture(180000))
  do trial=1,size(blind_cfos)
    call random_payload(payload); call sc_tx(payload,cfg,iq)
    offset=nint((.31_dp+.38_dp*real(trial-1,dp)/real(size(blind_cfos)-1,dp))*cfg%fs)
    cfo=blind_cfos(trial)
    gain=.4_dp+.7_dp*trial; phase=.81_dp*trial; capture=0
    do i=1,size(iq)
      capture(offset+i)=gain*iq(i)*exp(cmplx(0.0_dp,phase+2*PI*cfo*(i-1)/cfg%fs,dp))
    end do
    if(trial==2) then
      call seed_rng(912711)
      do i=1,size(capture)
        capture(i)=capture(i)+sqrt(.048_dp/2)*cmplx(rng_normal(),rng_normal(),dp)
      end do
    end if
    call sc_rx(capture,cfg,'blind',result)
    call check(result%crc_ok.and.all(result%payload==payload),'blind modem roundtrip across the public CFO range')
    call check(abs(result%start-offset)/cfg%fs<=.2_dp*cfg%ts,'blind timing estimate')
    call check(abs(result%cfo-cfo)<.1_dp,'blind frequency estimate')
    call check(result%evidence>=30.22075_dp,'blind frame passes public evidence gate')
  end do
  ! Exercise the Cartesian corners of the public timing/CFO search.  The
  ! minimum-size capture ends exactly at sample 125200 when start=8400, so
  ! these cases also guard the inclusive upper timing bound and array extent.
  allocate(minimum_capture(125200))
  do trial=1,size(boundary_starts)
    call random_payload(payload);call sc_tx(payload,cfg,iq)
    offset=boundary_starts(trial);cfo=boundary_cfos(trial);phase=.27_dp*trial;minimum_capture=0
    do i=1,size(iq)
      minimum_capture(offset+i)=iq(i)*exp(cmplx(0.0_dp,phase+2*PI*cfo*(i-1)/cfg%fs,dp))
    end do
    call sc_rx(minimum_capture,cfg,'blind',result)
    call check(result%crc_ok.and.all(result%payload==payload),'blind decode at exact timing/CFO search corner')
    call check(result%start==offset,'exact timing search corner is included')
    call check(abs(result%cfo-cfo)<1.0e-12_dp,'exact CFO search corner is included')
    call check(result%evidence>=30.22075_dp,'exact search-corner frame passes public evidence gate')
  end do
  ! A real receiver can preserve the modem tones while suppressing the old
  ! out-of-band noise guards.  The decoder must then use its robust in-band
  ! estimate instead of turning the soft metric into a false hard decision.
  call random_payload(payload);call sc_tx(payload,cfg,iq)
  offset=6000;cfo=137.25_dp;phase=.43_dp;capture=0
  do i=1,size(iq)
    capture(offset+i)=iq(i)*exp(cmplx(0.0_dp,phase+2*PI*cfo*(i-1)/cfg%fs,dp))
  end do
  target_snr=-16.0_dp;n0=1.0_dp/(2500.0_dp*10.0_dp**(target_snr/10.0_dp))
  allocate(wide_noise(size(capture)),filtered_noise(size(capture)));call seed_rng(551901)
  do i=1,size(wide_noise)
    wide_noise(i)=sqrt(cfg%fs*n0/2)*cmplx(rng_normal(),rng_normal(),dp)
  end do
  call lowpass_noise(wide_noise,cfg%fs,1500.0_dp,filtered_noise)
  call check(estimate_n0(filtered_noise,cfg%fs)<.01_dp*n0,'band-limited channel suppresses legacy noise guards')
  capture=capture+filtered_noise
  call sc_rx(capture,cfg,'blind',result)
  call check(result%crc_ok.and.all(result%payload==payload),'band-limited noisy receiver input decodes')
  call check(abs(result%cfo-cfo)<.5_dp,'band-limited input frequency estimate')
  call check(abs(result%noise_variance/(cfg%fs*n0)-1)<.25_dp,'in-band noise estimate tracks known density')
  call seed_rng(551977)
  do i=1,size(wide_noise)
    wide_noise(i)=sqrt(cfg%fs*n0/2)*cmplx(rng_normal(),rng_normal(),dp)
  end do
  call lowpass_noise(wide_noise,cfg%fs,1500.0_dp,filtered_noise)
  call sc_rx(filtered_noise,cfg,'blind',result)
  call check(.not.result%crc_ok,'band-limited noise alone is rejected')
  n0=.0004_dp; guard_mean=0; bin_mean=0
  call seed_rng(715913)
  do trial=1,4
    do i=1,size(noise)
      noise(i)=sqrt(cfg%fs*n0/2)*cmplx(rng_normal(),rng_normal(),dp)
    end do
    guard_mean=guard_mean+estimate_n0(noise,cfg%fs)
    call mfsk_statistics(noise,cfg,0,0.0_dp,energies)
    bin_mean=bin_mean+sum(energies)/size(energies)
  end do
  call check(abs(guard_mean/(4*n0)-1)<.03_dp,'noise guard scaling')
  call check(abs(bin_mean/(4*n0)-1)<.03_dp,'tone projection noise scaling')
  print '(A,I0,A)','PASS: ',checks,' QF256 core regression checks'
contains
  subroutine check(condition,label)
    logical, intent(in) :: condition
    character(*), intent(in) :: label
    if(.not.condition) then
      print '(A)','FAIL: '//label
      error stop 1
    end if
    checks=checks+1
  end subroutine
  subroutine random_payload(bits)
    integer, intent(out) :: bits(77)
    integer :: k
    do k=1,77
      state=modulo(16807_int64*state,2147483647_int64)
      bits(k)=merge(1,0,state>1073741823_int64)
    end do
  end subroutine
  subroutine lowpass_noise(input,fs,cutoff,output)
    complex(dp),intent(in) :: input(:)
    real(dp),intent(in) :: fs,cutoff
    complex(dp),intent(out) :: output(:)
    integer,parameter :: half=64
    real(dp) :: kernel(-half:half),window
    integer :: sample,tap,source
    do tap=-half,half
      window=.42_dp+.5_dp*cos(PI*real(tap,dp)/half)+.08_dp*cos(2*PI*real(tap,dp)/half)
      if(tap==0)then
        kernel(tap)=2*cutoff/fs
      else
        kernel(tap)=sin(2*PI*cutoff*real(tap,dp)/fs)/(PI*real(tap,dp))
      end if
      kernel(tap)=kernel(tap)*window
    end do
    kernel=kernel/sum(kernel);output=0
    do sample=1,size(input)
      do tap=-half,half
        source=sample-tap
        if(source>=1.and.source<=size(input))output(sample)=output(sample)+kernel(tap)*input(source)
      end do
    end do
  end subroutine lowpass_noise
end program
