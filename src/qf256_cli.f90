! SPDX-License-Identifier: GPL-3.0-or-later
module qf256_cli
  use iso_fortran_env,only:real64
  use, intrinsic::ieee_arithmetic,only:ieee_is_finite
  use qf256_api,only:qf256_encode,qf256_decode,sc_result,qf256_sample_rate,qf256_frame_samples,qf256_gate, &
    qf256_blind_cfo_limit_hz
  use qf256_io_mod,only:write_iq,read_iq,write_wav,read_wav
  implicit none
  private
  public::run_cli
  integer,parameter::dp=real64
contains
  subroutine run_cli(fixed_action)
    character(*),intent(in),optional::fixed_action
    character(4096)::arg,value,iq_path,wav_path,binary_bits,hexadecimal,message
    character(4096)::action,sync
    character(:),allocatable::json,payload_json,hex_json,snr_json
    integer::argc,i,status,bits(77),j,k,digit,offset,pos
    real(dp)::center,start_s,fs,gain
    complex(dp),allocatable::frame(:),capture(:)
    type(sc_result)::result
    logical::have_bits,have_hex,frame_only,center_set,start_set,sync_set,accepted,exists
    argc=command_argument_count();i=1;action=''
    if(present(fixed_action))then
      action=fixed_action
    else
      if(argc==0)call usage_error('Missing command: tx, rx, or info')
      call get_argument(1,arg);action=trim(arg);i=2
    end if
    if(action=='--help'.or.action=='help')then
      call help();return
    end if
    if(action=='--version'.or.action=='info')then
      if(argc>=i)call usage_error('info takes no options')
      print '(A)','{"modem":"QF256","version":"1.2.0","api_version":1,"sample_rate_hz":12000,"payload_bits":77,'// &
        '"frame_samples":116800,"frame_seconds":9.733333333333333,"capture_samples":180000,'// &
        '"gate":'//real_text(qf256_gate)//',"blind_cfo_limit_hz":'//real_text(qf256_blind_cfo_limit_hz)// &
        ',"snr_estimate_available":true,"snr_reference_bandwidth_hz":2500}'
      return
    end if
    if(action/='tx'.and.action/='rx')call usage_error('Unknown command')
    iq_path='';wav_path='';binary_bits='';hexadecimal='';sync='blind'
    have_bits=.false.;have_hex=.false.;frame_only=.false.;center_set=.false.;start_set=.false.;sync_set=.false.
    center=1500;start_s=.5_dp;fs=real(qf256_sample_rate,dp)
    do while(i<=argc)
      call get_argument(i,arg)
      if(trim(arg)=='--help')then
        call help();return
      end if
      if(trim(arg)=='--frame-only')then
        if(frame_only)call usage_error('Duplicate --frame-only')
        frame_only=.true.;i=i+1;cycle
      end if
      if(i==argc)call usage_error('Missing option value')
      call get_argument(i+1,value)
      select case(trim(arg))
      case('--bits')
        if(have_bits)call usage_error('Duplicate --bits')
        binary_bits=value;have_bits=.true.
      case('--hex')
        if(have_hex)call usage_error('Duplicate --hex')
        hexadecimal=value;have_hex=.true.
      case('--iq')
        if(len_trim(iq_path)/=0)call usage_error('Duplicate --iq')
        iq_path=value
      case('--wav')
        if(len_trim(wav_path)/=0)call usage_error('Duplicate --wav')
        wav_path=value
      case('--center-hz')
        if(center_set)call usage_error('Duplicate --center-hz')
        center=real_argument(trim(value),'--center-hz')
        center_set=.true.
      case('--start-seconds')
        if(start_set)call usage_error('Duplicate --start-seconds')
        start_s=real_argument(trim(value),'--start-seconds')
        start_set=.true.
      case('--sync')
        if(sync_set)call usage_error('Duplicate --sync')
        sync=value;sync_set=.true.
      case default
        call usage_error('Unknown option: '//trim(arg))
      end select
      i=i+2
    end do
    if(.not.ieee_is_finite(center).or.center<1100.or.center>4500)call usage_error('Center must be 1100..4500 Hz')
    if(.not.ieee_is_finite(start_s))call usage_error('Start must be finite')
    if(sync/='blind'.and.sync/='known')call usage_error('Sync must be blind or known')
    if(len_trim(iq_path)==0.and.len_trim(wav_path)==0)call usage_error('Specify --iq or --wav')
    if(center_set.and.len_trim(wav_path)==0)call usage_error('--center-hz applies only to WAV')
    if(action=='tx')then
      if(have_bits.eqv.have_hex)call usage_error('Specify exactly one of --bits or --hex')
      if(sync_set)call usage_error('--sync applies only to RX')
      if(frame_only.and.start_set)call usage_error('--frame-only and --start-seconds cannot be combined')
      if(.not.frame_only.and.(start_s<.3_dp.or.start_s>.7_dp))call usage_error('Start must be 0.3..0.7 s')
      if(trim(iq_path)==trim(wav_path))call usage_error('IQ and WAV output paths must differ')
      if(have_bits)then
        if(len_trim(binary_bits)/=77)call usage_error('Payload must contain exactly 77 binary digits')
        do j=1,77
          if(binary_bits(j:j)/='0'.and.binary_bits(j:j)/='1')call usage_error('Payload contains a non-binary digit')
          bits(j)=iachar(binary_bits(j:j))-iachar('0')
        end do
      else
        if(len_trim(hexadecimal)/=20)call usage_error('Hex payload must have 20 digits, first digit 0 or 1')
        bits=0;pos=0
        do j=1,20
          digit=index('0123456789ABCDEF',upper(hexadecimal(j:j)))-1
          if(digit<0)call usage_error('Invalid hexadecimal payload')
          if(j==1.and.digit>1)call usage_error('Hex payload exceeds 77 bits')
          do k=3,0,-1
            if(j==1.and.k>0)cycle
            pos=pos+1;bits(pos)=ibits(digit,k,1)
          end do
        end do
      end if
      if(len_trim(iq_path)>0)then
        inquire(file=trim(iq_path),exist=exists)
        if(exists)call usage_error('IQ output already exists; choose a new path')
      end if
      if(len_trim(wav_path)>0)then
        inquire(file=trim(wav_path),exist=exists)
        if(exists)call usage_error('WAV output already exists; choose a new path')
      end if
      call qf256_encode(bits,frame,status,message)
      if(status/=0)call usage_error(trim(message))
      if(frame_only)then
        start_s=0;call move_alloc(frame,capture)
      else
        allocate(capture(180000));capture=0;offset=nint(start_s*fs)
        capture(offset+1:offset+size(frame))=frame
      end if
      if(len_trim(iq_path)>0)then
        call write_iq(trim(iq_path),capture,status,message)
        if(status/=0)call usage_error(trim(message))
      end if
      gain=1
      if(len_trim(wav_path)>0)then
        call write_wav(trim(wav_path),capture,center,status,message,gain)
        if(status/=0)call usage_error(trim(message))
      end if
      json='{"modem":"QF256","operation":"tx","payload77":'//quote(bits_text(bits))// &
        ',"payload_hex":'//quote(hex_text(bits))//',"sample_rate_hz":12000,"samples":'//integer_text(size(capture))// &
        ',"duration_s":'//real_text(real(size(capture),dp)/fs)//',"active_duration_s":9.733333333333333'// &
        ',"start_s":'//real_text(start_s)//',"iq_format":"cf32le_interleaved_iq","iq_path":'//optional_path(iq_path)// &
        ',"wav_path":'//optional_path(wav_path)//',"audio_center_hz":'//real_text(center)// &
        ',"wav_gain":'//real_text(gain)//'}'
      print '(A)',json
    else
      if(have_bits.or.have_hex.or.frame_only.or.start_set)call usage_error('TX-only option used for RX')
      if(len_trim(iq_path)>0.and.len_trim(wav_path)>0)call usage_error('RX requires exactly one input')
      if(len_trim(iq_path)>0)then
        call read_iq(trim(iq_path),capture,status,message)
      else
        call read_wav(trim(wav_path),capture,center,status,message)
      end if
      if(status/=0)call usage_error(trim(message))
      call qf256_decode(capture,trim(sync),result,accepted,status,message)
      if(status/=0)call usage_error(trim(message))
      payload_json='null';hex_json='null';snr_json='null'
      if(accepted)then
        payload_json=quote(bits_text(result%payload));hex_json=quote(hex_text(result%payload))
        if(result%snr_valid)snr_json=real_text(result%snr_2500_db)
      end if
      json='{"modem":"QF256","operation":"rx","accepted":'//boolean_text(accepted)// &
        ',"crc_ok":'//boolean_text(result%crc_ok)//',"payload77":'//payload_json//',"payload_hex":'//hex_json// &
        ',"sample_rate_hz":12000,"samples":'//integer_text(size(capture))//',"sync":'//quote(trim(sync))// &
        ',"start_sample":'//integer_text(result%start)//',"start_s":'//real_text(result%start/fs)// &
        ',"cfo_hz":'//real_text(result%cfo)//',"noise_variance":'//real_text(result%noise_variance)// &
        ',"estimated_n0":'//real_text(result%noise_variance/fs)//',"snr_db":'//snr_json// &
        ',"snr_reference_bandwidth_hz":2500,"doppler_spread_hz":null'// &
        ',"evidence":'//real_text(result%evidence)//',"gate":'//real_text(qf256_gate)// &
        ',"iterations":'//integer_text(result%iterations)//',"decoder_cpu_ms":'//real_text(result%latency_ms)// &
        ',"input_frontend":'//quote(merge('iq ','wav',len_trim(iq_path)>0))// &
        ',"reference_iq_layout":'//boolean_text(len_trim(iq_path)>0.and.sync=='blind'.and.size(capture)==180000)//'}'
      print '(A)',json
      if(.not.accepted)stop 1
    end if
  end subroutine run_cli
  subroutine get_argument(index,value)
    integer,intent(in)::index
    character(*),intent(out)::value
    integer::status
    call get_command_argument(index,value,status=status)
    if(status/=0)call usage_error('Argument is unavailable or exceeds 4096 characters')
  end subroutine get_argument
  subroutine usage_error(message)
    character(*),intent(in)::message
    print '(A)','{"modem":"QF256","error":'//quote(message)//'}'
    stop 2
  end subroutine usage_error
  subroutine help()
    print '(A)','QF256 1.2.0 - 77-bit modem, 12000 complex samples/s'
    print '(A)','qf256 tx (--bits BITS77 | --hex HEX20) [--iq OUT.cf32] [--wav OUT.wav]'
    print '(A)','           [--center-hz 1500] [--frame-only | --start-seconds 0.5]'
    print '(A)','qf256 rx (--iq IN.cf32 | --wav IN.wav) [--center-hz 1500] [--sync blind|known]'
    print '(A)','Use spaces between options and values. Default TX: 15 s capture, burst at 0.5 s.'
    print '(A)','Frame-only TX: 9.733333 s; decode with --sync known (start 0, CFO 0).'
    print '(A)','Blind RX searches start 0.3..0.7 s and residual CFO -125..+125 Hz.'
    print '(A)','IQ: headerless float32 little-endian I,Q. WAV: PCM16LE mono 12000 Hz.'
    print '(A)','RX snr_db is an accepted-frame estimate in 2500 Hz; Doppler spread is unavailable.'
    print '(A)','Output: one JSON object; exit 0=success, 1=no accepted decode, 2=invalid input/I/O.'
    print '(A)','Existing output files are refused; choose a new output path.'
  end subroutine help
  function real_argument(text,label)result(value)
    character(*),intent(in)::text,label
    real(dp)::value
    integer::j,status
    if(len_trim(text)==0)call usage_error('Missing numeric value for '//label)
    do j=1,len_trim(text)
      if(index('0123456789.+-eEdD',text(j:j))==0)call usage_error('Invalid number for '//label)
    end do
    read(text,*,iostat=status)value
    if(status/=0)call usage_error('Invalid number for '//label)
    if(.not.ieee_is_finite(value))call usage_error('Nonfinite number for '//label)
  end function real_argument
  function quote(value)result(out)
    character(*),intent(in)::value
    character(:),allocatable::out
    character(6)::escaped
    integer::i,k
    out='"'
    do i=1,len_trim(value)
      k=iachar(value(i:i))
      if(k==34.or.k==92)then
        out=out//achar(92)//value(i:i)
      else if(k<32)then
        write(escaped,'(A,Z4.4)')achar(92)//'u',k
        out=out//escaped
      else
        out=out//value(i:i)
      end if
    end do
    out=out//'"'
  end function quote
  function optional_path(value)result(out)
    character(*),intent(in)::value
    character(:),allocatable::out
    out='null';if(len_trim(value)>0)out=quote(trim(value))
  end function optional_path
  function upper(ch)result(value)
    character,intent(in)::ch
    character::value
    integer::k
    value=ch;k=iachar(ch)
    if(k>=iachar('a').and.k<=iachar('f'))value=achar(k-32)
  end function upper
  function bits_text(bits)result(value)
    integer,intent(in)::bits(77)
    character(77)::value
    write(value,'(77I1)')bits
  end function bits_text
  function hex_text(bits)result(value)
    integer,intent(in)::bits(77)
    character(20)::value
    character(*),parameter::digits='0123456789ABCDEF'
    integer::all_bits(80),i,j,v
    all_bits=0;all_bits(4:)=bits
    do i=1,20
      v=0
      do j=1,4
        v=2*v+all_bits(4*(i-1)+j)
      end do
      value(i:i)=digits(v+1:v+1)
    end do
  end function hex_text
  function integer_text(value)result(out)
    integer,intent(in)::value
    character(:),allocatable::out
    character(32)::buffer
    write(buffer,'(I0)')value;out=trim(buffer)
  end function integer_text
  function real_text(value)result(out)
    real(dp),intent(in)::value
    character(:),allocatable::out
    character(48)::buffer
    if(.not.ieee_is_finite(value))then
      out='null';return
    end if
    write(buffer,'(ES25.17E3)')value;out=trim(adjustl(buffer))
  end function real_text
  function boolean_text(value)result(out)
    logical,intent(in)::value
    character(:),allocatable::out
    out='false';if(value)out='true'
  end function boolean_text
end module qf256_cli
