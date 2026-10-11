program test_io
  use iso_fortran_env,only:int8,int64,real32
  use, intrinsic :: ieee_arithmetic
  use numerics_mod,only:dp,PI
  use qf256_io_mod
  implicit none
  ! Run from the project root; the build target creates build/test/io first.
  character(*),parameter::work='build/test/io/'
  character(32),parameter::fixtures(15)=[character(32):: &
    'round.cf32','missing.cf32','nan-output.cf32','overflow-output.cf32','short.cf32','nan-input.cf32', &
    'round.wav','odd-junk.wav','data-first.wav','bad-rate.wav','bad-channel.wav','bad-format.wav', &
    'unbounded.wav','truncated.wav','odd-data.wav']
  complex(dp),allocatable::iq(:),back(:),bad(:)
  integer(int8),allocatable::original(:),modified(:)
  integer::i,n,status,u,checks,q,peakpcm
  real(dp)::gain,expected,error,t
  character(512)::message
  do i=1,size(fixtures)
    call remove_fixture(work//trim(fixtures(i)))
  end do
  checks=0;n=12000;allocate(iq(n))
  do i=1,n
    t=real(i-1,dp)/12000
    iq(i)=exp(cmplx(0.0_dp,2*PI*100*t,dp))
  end do
  call write_iq(work//'round.cf32',iq,status,message);call check(status==0,'CF32 write')
  call read_iq(work//'round.cf32',back,status,message);call check(status==0.and.size(back)==n,'CF32 read shape')
  ! Compare representations: file conversion must preserve every quantized bit.
  call check(all(transfer(back,[0_int64])== &
    transfer(cmplx(real(real(iq,dp),real32),real(aimag(iq),real32),dp),[0_int64])), &
    'CF32 exact quantized roundtrip')
  call write_iq(work//'round.cf32',2*iq,status,message);call check(status/=0,'Existing CF32 refused')
  call read_iq(work//'round.cf32',back,status,message);call check(maxval(abs(back-iq))<1e-7_dp,'Refused write preserves original')
  call read_iq(work//'missing.cf32',back,status,message);call check(status/=0.and..not.allocated(back),'Missing input status')
  allocate(bad(1));bad=cmplx(ieee_value(1.0_dp,ieee_quiet_nan),0.0_dp,dp)
  call write_iq(work//'nan-output.cf32',bad,status,message);call check(status/=0,'NaN source refused')
  bad=cmplx(1e100_dp,0.0_dp,dp)
  call write_iq(work//'overflow-output.cf32',bad,status,message);call check(status/=0,'CF32 overflow refused')
  allocate(modified(7));modified=0;call dump(work//'short.cf32',modified);deallocate(modified)
  call read_iq(work//'short.cf32',back,status,message);call check(status/=0.and..not.allocated(back),'Partial IQ sample refused')
  allocate(modified(8));modified=0;modified(3)=-64;modified(4)=127
  call dump(work//'nan-input.cf32',modified);deallocate(modified)
  call read_iq(work//'nan-input.cf32',back,status,message);call check(status/=0.and..not.allocated(back),'NaN file refused')
  call write_wav(work//'round.wav',iq,1500.0_dp,status,message,gain);call check(status==0,'WAV write')
  call check(gain>0.and.ieee_is_finite(gain),'Finite volume gain')
  call write_wav(work//'round.wav',2*iq,1500.0_dp,status,message);call check(status/=0,'Existing WAV refused')
  call read_wav(work//'round.wav',back,1500.0_dp,status,message)
  call check(status==0.and.size(back)==n,'Analytic input preserves N')
  open(newunit=u,file=work//'round.wav',access='stream',form='unformatted',status='old')
  allocate(original(44+2*n));read(u)original;close(u)
  peakpcm=0;error=0
  do i=1,n
    q=iand(int(original(43+2*i)),255)+256*iand(int(original(44+2*i)),255)
    if(q>=32768)q=q-65536
    peakpcm=max(peakpcm,abs(q));expected=real(q,dp)/32768
    t=real(i-1,dp)/12000
    error=max(error,abs(sqrt(2.0_dp)*real(back(i)*exp(cmplx(0.0_dp,2*PI*1500*t,dp)),dp)-expected))
  end do
  print '(A,ES24.16)','Analytic error=',error
  call check(error<1e-10_dp,'Analytic reconstruction preserves real audio including edges')
  call check(abs(20*log10(peakpcm/32767.0_dp)+3)<.001_dp,'PCM peak target')
  print '(A,ES12.4,A,F12.7)','Analytic real-audio reconstruction error=',error,' peak dBFS=',20*log10(peakpcm/32767.0_dp)
  call check(maxval(abs(back(501:n-500)-gain*iq(501:n-500)*32767/32768))<.003_dp,'Complex phase recovered away from burst edges')
  allocate(modified(size(original)+12));modified=0
  modified(:12)=original(:12);call put(modified(5:8),int(size(modified)-8,int64))
  modified(13:16)=[74_int8,85_int8,78_int8,75_int8];call put(modified(17:20),3_int64)
  modified(21:23)=[65_int8,66_int8,67_int8];modified(25:)=original(13:)
  call dump(work//'odd-junk.wav',modified);deallocate(modified)
  call read_wav(work//'odd-junk.wav',back,1500.0_dp,status,message);call check(status==0.and.size(back)==n,'Bounded odd unknown chunk plus pad accepted')
  allocate(modified(size(original)));modified=original
  modified(13:20)=original(37:44);modified(21:20+2*n)=original(45:);modified(21+2*n:)=original(13:36)
  call dump(work//'data-first.wav',modified)
  call read_wav(work//'data-first.wav',back,1500.0_dp,status,message);call check(status==0,'Data before format accepted')
  modified=original;call put(modified(25:28),16000_int64);call dump(work//'bad-rate.wav',modified)
  call read_wav(work//'bad-rate.wav',back,1500.0_dp,status,message);call check(status/=0.and..not.allocated(back),'Wrong sample rate refused')
  modified=original;call put(modified(23:24),2_int64);call dump(work//'bad-channel.wav',modified)
  call read_wav(work//'bad-channel.wav',back,1500.0_dp,status,message);call check(status/=0,'Stereo refused')
  modified=original;call put(modified(21:22),3_int64);call dump(work//'bad-format.wav',modified)
  call read_wav(work//'bad-format.wav',back,1500.0_dp,status,message);call check(status/=0,'Float WAV refused')
  modified=original;call put(modified(41:44),4294967295_int64);call dump(work//'unbounded.wav',modified)
  call read_wav(work//'unbounded.wav',back,1500.0_dp,status,message);call check(status/=0,'Overflowing chunk refused')
  call dump(work//'truncated.wav',original(:size(original)-1))
  call read_wav(work//'truncated.wav',back,1500.0_dp,status,message);call check(status/=0,'Truncated RIFF refused')
  modified=original;call put(modified(41:44),2_int64*n-1);call dump(work//'odd-data.wav',modified)
  call read_wav(work//'odd-data.wav',back,1500.0_dp,status,message);call check(status/=0,'Odd PCM byte count refused')
  call read_wav(work//'round.wav',back,1000.0_dp,status,message);call check(status/=0,'Out-of-range center refused')
  print '(A,I0,A)','PASS ',checks,' IO checks'
contains
  subroutine remove_fixture(path)
    character(*),intent(in)::path
    logical::exists
    integer::unit,ios
    inquire(file=path,exist=exists)
    if(.not.exists)return
    open(newunit=unit,file=path,access='stream',form='unformatted',status='old',iostat=ios)
    if(ios/=0)error stop 'Cannot reset an IO-test fixture'
    close(unit,status='delete',iostat=ios)
    if(ios/=0)error stop 'Cannot delete an IO-test fixture'
  end subroutine remove_fixture
  subroutine check(ok,label)
    logical,intent(in)::ok
    character(*),intent(in)::label
    if(.not.ok)then
      print '(A)','FAIL '//label//' '//trim(message)
      error stop 1
    end if
    checks=checks+1
  end subroutine
  subroutine put(bytes,value)
    integer(int8),intent(out)::bytes(:)
    integer(int64),intent(in)::value
    integer::i,v
    do i=1,size(bytes)
      v=int(ibits(value,8*(i-1),8));if(v>=128)v=v-256
      bytes(i)=int(v,int8)
    end do
  end subroutine
  subroutine dump(path,bytes)
    character(*),intent(in)::path
    integer(int8),intent(in)::bytes(:)
    integer::u
    open(newunit=u,file=path,access='stream',form='unformatted',status='new')
    write(u)bytes;close(u)
  end subroutine
end program
