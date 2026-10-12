! SPDX-License-Identifier: GPL-3.0-or-later
! Binary frontends for QF256 complex IQ at 12000 samples/s.
! CF32LE is headerless interleaved IEEE754 real32 I,Q, with no rescaling.
! WAV is signed 16-bit little-endian mono PCM at 12000 Hz.
! Export rounds 32767*audio; input PCM is divided by 32768.
module qf256_io_mod
  use iso_fortran_env,only:int8,int32,int64,real32
  use, intrinsic :: ieee_arithmetic,only:ieee_is_finite
  use numerics_mod,only:dp,PI
  use waveform_metrics_mod,only:fft_forward
  implicit none
  private
  public :: write_iq,read_iq,write_wav,read_wav
  integer,parameter :: sample_rate=12000,buffer_bytes=65536
  integer(int64),parameter :: max_input_samples=180000_int64
  real(dp),parameter :: audio_peak=10.0_dp**(-3.0_dp/20),sqrt_two=sqrt(2.0_dp)
contains
  subroutine fail(status,message,detail)
    integer,intent(out) :: status
    character(*),intent(out) :: message
    character(*),intent(in) :: detail
    status=1;message=detail
  end subroutine fail

  logical function valid_path(path)
    character(*),intent(in) :: path
    valid_path=len_trim(path)>0.and.index(path,achar(0))==0
  end function valid_path

  logical function valid_center(center)
    real(dp),intent(in) :: center
    valid_center=.false.
    if(.not.ieee_is_finite(center))return
    valid_center=center>=1100.0_dp.and.center<=4500.0_dp
  end function valid_center

  logical function valid_iq(iq)
    complex(dp),intent(in) :: iq(:)
    valid_iq=size(iq)>0
    if(.not.valid_iq)return
    valid_iq=all(ieee_is_finite(real(iq,dp))).and.all(ieee_is_finite(aimag(iq)))
  end function valid_iq

  pure integer(int64) function unsigned_le(bytes) result(value)
    integer(int8),intent(in) :: bytes(:)
    integer :: i
    value=0
    do i=1,size(bytes)
      value=ior(value,ishft(iand(int(bytes(i),int64),255_int64),8*(i-1)))
    end do
  end function unsigned_le

  pure subroutine put_unsigned(bytes,value)
    integer(int8),intent(out) :: bytes(:)
    integer(int64),intent(in) :: value
    integer :: i,b
    do i=1,size(bytes)
      b=int(ibits(value,8*(i-1),8))
      if(b>=128)b=b-256
      bytes(i)=int(b,int8)
    end do
  end subroutine put_unsigned

  pure logical function fourcc(bytes,text)
    integer(int8),intent(in) :: bytes(4)
    character(4),intent(in) :: text
    integer :: i
    fourcc=.true.
    do i=1,4
      if(iand(int(bytes(i)),255)/=iachar(text(i:i)))fourcc=.false.
    end do
  end function fourcc

  pure subroutine put_fourcc(bytes,text)
    integer(int8),intent(out) :: bytes(4)
    character(4),intent(in) :: text
    integer :: i
    do i=1,4
      bytes(i)=int(iachar(text(i:i)),int8)
    end do
  end subroutine put_fourcc

  pure real(real32) function unpack_float(bytes) result(value)
    integer(int8),intent(in) :: bytes(4)
    integer(int32) :: pattern
    integer :: i
    pattern=0_int32
    do i=1,4
      pattern=ior(pattern,ishft(iand(int(bytes(i),int32),255_int32),8*(i-1)))
    end do
    value=transfer(pattern,value)
  end function unpack_float

  pure subroutine pack_float(bytes,value)
    integer(int8),intent(out) :: bytes(4)
    real(real32),intent(in) :: value
    integer(int32) :: pattern
    integer :: i,b
    pattern=transfer(value,pattern)
    do i=1,4
      b=int(ibits(pattern,8*(i-1),8))
      if(b>=128)b=b-256
      bytes(i)=int(b,int8)
    end do
  end subroutine pack_float

  subroutine write_iq(path,iq,status,message)
    character(*),intent(in) :: path
    complex(dp),intent(in) :: iq(:)
    integer,intent(out) :: status
    character(*),intent(out) :: message
    integer(int8) :: bytes(buffer_bytes)
    integer :: unit,ios,ignored,first,last,i,k
    character(512) :: detail
    status=0;message=''
    if(.not.valid_path(path))then
      call fail(status,message,'Invalid output path');return
    end if
    if(.not.valid_iq(iq))then
      call fail(status,message,'IQ must be nonempty and finite');return
    end if
    if(any(abs(real(iq,dp))>real(huge(1.0_real32),dp)).or. &
       any(abs(aimag(iq))>real(huge(1.0_real32),dp)))then
      call fail(status,message,'IQ exceeds finite CF32 range');return
    end if
    open(newunit=unit,file=trim(path),access='stream',form='unformatted',action='write', &
      status='new',iostat=ios,iomsg=detail)
    if(ios/=0)then
      call fail(status,message,'Cannot create new IQ file: '//trim(detail));return
    end if
    do first=1,size(iq),buffer_bytes/8
      last=min(size(iq),first+buffer_bytes/8-1);k=0
      do i=first,last
        call pack_float(bytes(k+1:k+4),real(real(iq(i),dp),real32))
        call pack_float(bytes(k+5:k+8),real(aimag(iq(i)),real32));k=k+8
      end do
      write(unit,iostat=ios,iomsg=detail)bytes(:k)
      if(ios/=0)then
        close(unit,status='delete',iostat=ignored)
        call fail(status,message,'IQ write failed: '//trim(detail));return
      end if
    end do
    close(unit,iostat=ios,iomsg=detail)
    if(ios/=0)call fail(status,message,'IQ close failed: '//trim(detail))
  end subroutine write_iq

  subroutine read_iq(path,iq,status,message)
    character(*),intent(in) :: path
    complex(dp),allocatable,intent(out) :: iq(:)
    integer,intent(out) :: status
    character(*),intent(out) :: message
    integer(int8) :: bytes(buffer_bytes)
    integer(int64) :: length,n64
    integer :: unit,ios,ignored,n,first,last,i,k
    real(real32) :: re,im
    character(512) :: detail
    status=0;message=''
    if(.not.valid_path(path))then
      call fail(status,message,'Invalid input path');return
    end if
    open(newunit=unit,file=trim(path),access='stream',form='unformatted',action='read', &
      status='old',iostat=ios,iomsg=detail)
    if(ios/=0)then
      call fail(status,message,'Cannot open IQ file: '//trim(detail));return
    end if
    length=0
    inquire(unit=unit,size=length,iostat=ios,iomsg=detail)
    if(ios/=0)then
      close(unit,iostat=ignored);call fail(status,message,'Cannot determine IQ size: '//trim(detail));return
    end if
    if(length<=0.or.modulo(length,8_int64)/=0)then
      close(unit,iostat=ignored);call fail(status,message,'CF32LE length must be a positive multiple of 8 bytes');return
    end if
    n64=length/8
    if(n64>max_input_samples)then
      close(unit,iostat=ignored);call fail(status,message,'IQ capture exceeds 180000 complex samples');return
    end if
    if(n64>huge(n)-buffer_bytes)then
      close(unit,iostat=ignored);call fail(status,message,'IQ file exceeds supported array size');return
    end if
    n=int(n64);allocate(iq(n),stat=ios,errmsg=detail)
    if(ios/=0)then
      close(unit,iostat=ignored);call fail(status,message,'Cannot allocate IQ array: '//trim(detail));return
    end if
    do first=1,n,buffer_bytes/8
      last=min(n,first+buffer_bytes/8-1)
      read(unit,iostat=ios,iomsg=detail)bytes(:8*(last-first+1))
      if(ios/=0)then
        deallocate(iq);close(unit,iostat=ignored)
        call fail(status,message,'Incomplete IQ data: '//trim(detail));return
      end if
      k=0
      do i=first,last
        re=unpack_float(bytes(k+1:k+4));im=unpack_float(bytes(k+5:k+8));k=k+8
        if(.not.ieee_is_finite(re).or..not.ieee_is_finite(im))then
          deallocate(iq);close(unit,iostat=ignored)
          call fail(status,message,'IQ file contains a nonfinite float');return
        end if
        iq(i)=cmplx(real(re,dp),real(im,dp),dp)
      end do
    end do
    close(unit,iostat=ios,iomsg=detail)
    if(ios/=0)then
      deallocate(iq);call fail(status,message,'IQ close failed: '//trim(detail))
    end if
  end subroutine read_iq

  subroutine write_wav(path,iq,center_hz,status,message,gain)
    character(*),intent(in) :: path
    complex(dp),intent(in) :: iq(:)
    real(dp),intent(in) :: center_hz
    integer,intent(out) :: status
    character(*),intent(out) :: message
    real(dp),optional,intent(out) :: gain
    integer(int8) :: header(44),bytes(buffer_bytes)
    integer :: unit,ios,ignored,i,q,k,first,last
    integer(int64) :: data_bytes
    real(dp) :: scale,peak,value,phase,volume
    character(512) :: detail
    status=0;message='';if(present(gain))gain=0
    if(.not.valid_path(path))then
      call fail(status,message,'Invalid output path');return
    end if
    if(.not.valid_center(center_hz))then
      call fail(status,message,'WAV center frequency must be finite and between 1100 and 4500 Hz');return
    end if
    if(.not.valid_iq(iq))then
      call fail(status,message,'IQ must be nonempty and finite');return
    end if
    data_bytes=2_int64*size(iq,kind=int64)
    if(data_bytes>4294967295_int64-36.or.size(iq,kind=int64)>huge(i)-buffer_bytes)then
      call fail(status,message,'Audio exceeds RIFF or supported array size');return
    end if
    ! Normalize before mixing to avoid intermediate overflow for finite large IQ.
    scale=max(maxval(abs(real(iq,dp))),maxval(abs(aimag(iq))));peak=0
    if(scale>0)then
      do i=1,size(iq)
        phase=2*PI*center_hz*real(i-1,dp)/sample_rate
        value=sqrt_two*real((iq(i)/scale)*cmplx(cos(phase),sin(phase),dp),dp)
        peak=max(peak,abs(value))
      end do
    end if
    volume=0
    if(peak>0)volume=audio_peak/peak
    if(scale>0.and.peak>0)then
      if(scale<volume/huge(1.0_dp))then
        call fail(status,message,'IQ scale is too small for a finite playback gain');return
      end if
    end if
    header=0
    call put_fourcc(header(1:4),'RIFF');call put_unsigned(header(5:8),36_int64+data_bytes)
    call put_fourcc(header(9:12),'WAVE');call put_fourcc(header(13:16),'fmt ')
    call put_unsigned(header(17:20),16_int64);call put_unsigned(header(21:22),1_int64)
    call put_unsigned(header(23:24),1_int64);call put_unsigned(header(25:28),int(sample_rate,int64))
    call put_unsigned(header(29:32),int(2*sample_rate,int64));call put_unsigned(header(33:34),2_int64)
    call put_unsigned(header(35:36),16_int64);call put_fourcc(header(37:40),'data')
    call put_unsigned(header(41:44),data_bytes)
    open(newunit=unit,file=trim(path),access='stream',form='unformatted',action='write', &
      status='new',iostat=ios,iomsg=detail)
    if(ios/=0)then
      call fail(status,message,'Cannot create new WAV file: '//trim(detail));return
    end if
    write(unit,iostat=ios,iomsg=detail)header
    if(ios/=0)then
      close(unit,status='delete',iostat=ignored);call fail(status,message,'WAV header write failed: '//trim(detail));return
    end if
    do first=1,size(iq),buffer_bytes/2
      last=min(size(iq),first+buffer_bytes/2-1);k=0
      do i=first,last
        value=0
        if(scale>0.and.peak>0)then
          phase=2*PI*center_hz*real(i-1,dp)/sample_rate
          value=volume*sqrt_two*real((iq(i)/scale)*cmplx(cos(phase),sin(phase),dp),dp)
        end if
        q=nint(32767.0_dp*value)
        ! The -3 dBFS target keeps quantized values within the PCM16 range.
        if(q< -32768.or.q>32767)then
          close(unit,status='delete',iostat=ignored);call fail(status,message,'Unexpected PCM clipping');return
        end if
        call put_unsigned(bytes(k+1:k+2),int(q,int64));k=k+2
      end do
      write(unit,iostat=ios,iomsg=detail)bytes(:k)
      if(ios/=0)then
        close(unit,status='delete',iostat=ignored);call fail(status,message,'WAV data write failed: '//trim(detail));return
      end if
    end do
    close(unit,iostat=ios,iomsg=detail)
    if(ios/=0)then
      call fail(status,message,'WAV close failed: '//trim(detail));return
    end if
    if(present(gain))then
      gain=1
      if(scale>0.and.peak>0)gain=volume/scale
    end if
  end subroutine write_wav

  subroutine read_wav(path,iq,center_hz,status,message)
    character(*),intent(in) :: path
    complex(dp),allocatable,intent(out) :: iq(:)
    real(dp),intent(in) :: center_hz
    integer,intent(out) :: status
    character(*),intent(out) :: message
    integer(int8) :: header(16),bytes(buffer_bytes)
    integer(int64) :: length,riff_end,position,chunk_size,data_position,data_size,padded,n64,nf64
    integer :: unit,ios,ignored,n,nf,i,first,last,k,q
    logical :: found_format,found_data
    real(dp) :: phase
    complex(dp),allocatable :: spectrum(:)
    character(512) :: detail
    status=0;message=''
    if(.not.valid_path(path))then
      call fail(status,message,'Invalid input path');return
    end if
    if(.not.valid_center(center_hz))then
      call fail(status,message,'WAV center frequency must be finite and between 1100 and 4500 Hz');return
    end if
    open(newunit=unit,file=trim(path),access='stream',form='unformatted',action='read', &
      status='old',iostat=ios,iomsg=detail)
    if(ios/=0)then
      call fail(status,message,'Cannot open WAV file: '//trim(detail));return
    end if
    length=0
    inquire(unit=unit,size=length,iostat=ios,iomsg=detail)
    if(ios/=0.or.length<12)then
      close(unit,iostat=ignored);call fail(status,message,'Incomplete RIFF header');return
    end if
    read(unit,pos=1,iostat=ios)header(:12)
    if(ios/=0)then
      close(unit,iostat=ignored);call fail(status,message,'Cannot read RIFF header');return
    end if
    if(.not.fourcc(header(1:4),'RIFF').or..not.fourcc(header(9:12),'WAVE'))then
      close(unit,iostat=ignored);call fail(status,message,'Expected little-endian RIFF/WAVE');return
    end if
    riff_end=8+unsigned_le(header(5:8))
    if(riff_end<12.or.riff_end/=length)then
      close(unit,iostat=ignored);call fail(status,message,'RIFF length does not match file or is invalid');return
    end if
    position=13;found_format=.false.;found_data=.false.;data_position=0;data_size=0
    do while(position<=riff_end)
      if(riff_end-position+1<8)then
        close(unit,iostat=ignored);call fail(status,message,'Incomplete RIFF chunk header');return
      end if
      read(unit,pos=position,iostat=ios)header(:8)
      if(ios/=0)then
        close(unit,iostat=ignored);call fail(status,message,'Cannot read RIFF chunk');return
      end if
      chunk_size=unsigned_le(header(5:8));padded=chunk_size+modulo(chunk_size,2_int64)
      if(padded>riff_end-position-7)then
        close(unit,iostat=ignored);call fail(status,message,'RIFF chunk or padding exceeds declared boundary');return
      end if
      if(fourcc(header(1:4),'fmt '))then
        if(found_format.or.chunk_size<16)then
          close(unit,iostat=ignored);call fail(status,message,'Duplicate or incomplete WAV format chunk');return
        end if
        read(unit,pos=position+8,iostat=ios)header(:16)
        if(ios/=0)then
          close(unit,iostat=ignored);call fail(status,message,'Cannot read WAV format');return
        end if
        if(unsigned_le(header(1:2))/=1.or.unsigned_le(header(3:4))/=1.or. &
           unsigned_le(header(5:8))/=sample_rate.or.unsigned_le(header(9:12))/=2*sample_rate.or. &
           unsigned_le(header(13:14))/=2.or.unsigned_le(header(15:16))/=16)then
          close(unit,iostat=ignored);call fail(status,message,'WAV must be PCM16 mono 12000 Hz with valid byte rate/alignment');return
        end if
        found_format=.true.
      else if(fourcc(header(1:4),'data'))then
        if(found_data.or.chunk_size==0.or.modulo(chunk_size,2_int64)/=0)then
          close(unit,iostat=ignored);call fail(status,message,'WAV needs one nonempty even-length PCM data chunk');return
        end if
        found_data=.true.;data_position=position+8;data_size=chunk_size
      end if
      position=position+8+padded
    end do
    if(.not.found_format.or..not.found_data)then
      close(unit,iostat=ignored);call fail(status,message,'WAV format or data chunk missing');return
    end if
    n64=data_size/2
    if(n64>max_input_samples)then
      close(unit,iostat=ignored);call fail(status,message,'WAV capture exceeds 180000 samples');return
    end if
    nf64=1
    do while(nf64<2*n64)
      nf64=2*nf64
    end do
    if(n64>huge(n)-buffer_bytes.or.nf64>huge(nf))then
      close(unit,iostat=ignored);call fail(status,message,'WAV exceeds supported FFT size');return
    end if
    n=int(n64);nf=int(nf64);allocate(spectrum(nf),stat=ios,errmsg=detail)
    if(ios/=0)then
      close(unit,iostat=ignored);call fail(status,message,'Cannot allocate analytic FFT: '//trim(detail));return
    end if
    spectrum=0
    do first=1,n,buffer_bytes/2
      last=min(n,first+buffer_bytes/2-1)
      read(unit,pos=data_position+2_int64*(first-1),iostat=ios)bytes(:2*(last-first+1))
      if(ios/=0)then
        close(unit,iostat=ignored);call fail(status,message,'Incomplete PCM sample data');return
      end if
      k=0
      do i=first,last
        q=int(unsigned_le(bytes(k+1:k+2)));k=k+2
        if(q>=32768)q=q-65536
        spectrum(i)=real(q,dp)/32768.0_dp
      end do
    end do
    close(unit,iostat=ios,iomsg=detail)
    if(ios/=0)then
      call fail(status,message,'WAV close failed: '//trim(detail));return
    end if
    call fft_forward(spectrum)
    ! DC and Nyquist weights 1, strictly positive frequencies 2, negative 0.
    spectrum(2:nf/2)=2*spectrum(2:nf/2)
    spectrum(nf/2+2:nf)=0
    spectrum=conjg(spectrum);call fft_forward(spectrum);spectrum=conjg(spectrum)/nf
    allocate(iq(n),stat=ios,errmsg=detail)
    if(ios/=0)then
      call fail(status,message,'Cannot allocate recovered IQ: '//trim(detail));return
    end if
    do i=1,n
      phase=-2*PI*center_hz*real(i-1,dp)/sample_rate
      iq(i)=spectrum(i)*cmplx(cos(phase),sin(phase),dp)/sqrt_two
    end do
    if(.not.valid_iq(iq))then
      deallocate(iq);call fail(status,message,'Nonfinite result from analytic audio conversion')
    end if
  end subroutine read_wav
end module qf256_io_mod
