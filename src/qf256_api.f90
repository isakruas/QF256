! SPDX-License-Identifier: GPL-3.0-or-later
! Validated Fortran and C adapters for the QF256 DSP/FEC core.
module qf256_api
  use iso_fortran_env, only: real64
  use iso_c_binding, only: c_ptr,c_associated,c_f_pointer,c_int8_t,c_int32_t,c_float,c_double
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
  use mfsk_iq_mod, only: sc_config,sc_result,setup_sc,sc_tx,sc_rx,blind_cfo_limit_hz,blind_hf_cfo_limit_hz
  implicit none
  private
  integer,parameter,public :: qf256_api_version=1
  integer,parameter,public :: qf256_sample_rate=12000,qf256_frame_samples=116800
  integer,parameter,public :: qf256_payload_bits=77,qf256_blind_min_samples=125200,qf256_max_samples=180000
  real(real64),parameter,public :: qf256_gate=30.220758775848424_real64
  real(real64),parameter,public :: qf256_snr_reference_hz=2500.0_real64
  real(real64),parameter,public :: qf256_blind_cfo_limit_hz=blind_cfo_limit_hz
  real(real64),parameter,public :: qf256_blind_hf_cfo_limit_hz=blind_hf_cfo_limit_hz
  integer,parameter,public :: qf256_ok=0,qf256_invalid_bits=1,qf256_invalid_sync=2
  integer,parameter,public :: qf256_invalid_length=3,qf256_nonfinite=4,qf256_buffer_too_small=5
  integer,parameter,public :: qf256_invalid_argument=6,qf256_numeric_range=7
  integer,parameter,public :: qf256_sync_known=0,qf256_sync_blind=1,qf256_sync_blind_hf=2
  public :: qf256_encode,qf256_decode,sc_result,qf256_result_c
  public :: qf256_tx_cf32,qf256_rx_cf32

  type,bind(C) :: qf256_result_c
    integer(c_int8_t) :: payload(77),reserved(3)
    integer(c_int32_t) :: crc_ok,accepted,start_samples,iterations
    real(c_double) :: start_seconds,cfo_hz,noise_variance,evidence,latency_ms
    real(c_double) :: snr_2500_db
    integer(c_int32_t) :: snr_valid,reserved2
  end type qf256_result_c

contains
  subroutine report_status(status,message,code,text)
    integer,intent(out) :: status
    character(*),intent(out),optional :: message
    integer,intent(in) :: code
    character(*),intent(in) :: text
    status=code
    if(present(message))message=text
  end subroutine report_status

  subroutine fixed_config(cfg)
    type(sc_config),intent(out) :: cfg
    call setup_sc(5,real(qf256_frame_samples,real64)/qf256_sample_rate,real(qf256_sample_rate,real64),cfg)
  end subroutine fixed_config

  subroutine qf256_encode(bits,iq,status,message)
    integer,intent(in) :: bits(:)
    complex(real64),allocatable,intent(out) :: iq(:)
    integer,intent(out) :: status
    character(*),intent(out),optional :: message
    type(sc_config) :: cfg
    if(size(bits)/=qf256_payload_bits)then
      call report_status(status,message,qf256_invalid_bits,'Payload must contain exactly 77 integer bits')
      return
    end if
    if(any(bits<0.or.bits>1))then
      call report_status(status,message,qf256_invalid_bits,'Every payload bit must be 0 or 1')
      return
    end if
    call fixed_config(cfg)
    call sc_tx(bits,cfg,iq)
    call report_status(status,message,qf256_ok,'OK')
  end subroutine qf256_encode

  subroutine qf256_decode(iq,sync,result,accepted,status,message)
    complex(real64),intent(in) :: iq(:)
    character(*),intent(in) :: sync
    type(sc_result),intent(out) :: result
    logical,intent(out) :: accepted
    integer,intent(out) :: status
    character(*),intent(out),optional :: message
    type(sc_config) :: cfg
    integer :: minimum
    result=sc_result();accepted=.false.
    select case(trim(sync))
    case('known');minimum=qf256_frame_samples
    case('blind','blind-hf');minimum=qf256_blind_min_samples
    case default
      call report_status(status,message,qf256_invalid_sync,'Synchronization must be known, blind or blind-hf')
      return
    end select
    if(size(iq)<minimum.or.size(iq)>qf256_max_samples)then
      call report_status(status,message,qf256_invalid_length,'Capture length outside the fixed mode limits')
      return
    end if
    if(.not.all(ieee_is_finite(real(iq,real64))).or..not.all(ieee_is_finite(aimag(iq))))then
      call report_status(status,message,qf256_nonfinite,'IQ components must be finite')
      return
    end if
    ! Keep even the cubic metric numerator finite at the core's N0 floor.
    ! Every finite float32 input lies safely inside this numerical bound.
    if(maxval(abs(real(iq,real64)))>1.0e90_real64.or.maxval(abs(aimag(iq)))>1.0e90_real64)then
      call report_status(status,message,qf256_numeric_range,'IQ component magnitude exceeds the numerical safety limit 1e90')
      return
    end if
    call fixed_config(cfg)
    call sc_rx(iq,cfg,trim(sync),result)
    accepted=result%crc_ok.and.result%evidence>=qf256_gate
    call report_status(status,message,qf256_ok,'OK')
  end subroutine qf256_decode

  subroutine clear_c_result(result)
    type(qf256_result_c),intent(out) :: result
    result%payload=0;result%reserved=0
    result%crc_ok=0;result%accepted=0;result%start_samples=0;result%iterations=0
    result%start_seconds=0;result%cfo_hz=0;result%noise_variance=0;result%evidence=0;result%latency_ms=0
    result%snr_2500_db=0;result%snr_valid=0;result%reserved2=0
  end subroutine clear_c_result

  subroutine fill_c_result(output,result,accepted)
    type(qf256_result_c),intent(out) :: output
    type(sc_result),intent(in) :: result
    logical,intent(in) :: accepted
    call clear_c_result(output)
    output%payload=int(result%payload,c_int8_t)
    output%crc_ok=merge(1_c_int32_t,0_c_int32_t,result%crc_ok)
    output%accepted=merge(1_c_int32_t,0_c_int32_t,accepted)
    output%start_samples=int(result%start,c_int32_t)
    output%iterations=int(result%iterations,c_int32_t)
    output%start_seconds=real(result%start,c_double)/qf256_sample_rate
    output%cfo_hz=result%cfo;output%noise_variance=result%noise_variance
    output%evidence=result%evidence;output%latency_ms=result%latency_ms
    output%snr_2500_db=real(result%snr_2500_db,c_double)
    output%snr_valid=merge(1_c_int32_t,0_c_int32_t,result%snr_valid)
  end subroutine fill_c_result

  subroutine qf256_tx_cf32(payload_ptr,iq_ptr,capacity_complex,written_ptr,status_ptr) bind(C,name='qf256_tx_cf32')
    type(c_ptr),value :: payload_ptr,iq_ptr,written_ptr,status_ptr
    integer(c_int32_t),value :: capacity_complex
    integer(c_int8_t),pointer :: payload(:)
    real(c_float),pointer :: output(:)
    integer(c_int32_t),pointer :: written,status
    complex(real64),allocatable :: iq(:)
    integer :: bits(77),local_status,i
    ! An absent status pointer cannot receive an error; return without access.
    if(.not.c_associated(status_ptr))return
    call c_f_pointer(status_ptr,status);status=qf256_invalid_argument
    if(c_associated(written_ptr))then
      call c_f_pointer(written_ptr,written);written=0
    else
      return
    end if
    if(.not.c_associated(payload_ptr).or..not.c_associated(iq_ptr))return
    if(capacity_complex<qf256_frame_samples)then
      status=qf256_buffer_too_small
      return
    end if
    call c_f_pointer(payload_ptr,payload,[qf256_payload_bits]);bits=int(payload)
    call qf256_encode(bits,iq,local_status)
    status=int(local_status,c_int32_t)
    if(local_status/=qf256_ok)return
    call c_f_pointer(iq_ptr,output,[2*qf256_frame_samples])
    do i=1,qf256_frame_samples
      output(2*i-1)=real(iq(i),c_float);output(2*i)=real(aimag(iq(i)),c_float)
    end do
    written=qf256_frame_samples
  end subroutine qf256_tx_cf32

  subroutine qf256_rx_cf32(iq_ptr,ncomplex,sync_mode,result_ptr,status_ptr) bind(C,name='qf256_rx_cf32')
    type(c_ptr),value :: iq_ptr,result_ptr,status_ptr
    integer(c_int32_t),value :: ncomplex,sync_mode
    real(c_float),pointer :: input(:)
    integer(c_int32_t),pointer :: status
    type(qf256_result_c),pointer :: output
    complex(real64),allocatable :: iq(:)
    type(sc_result) :: result
    character(8) :: sync
    integer :: minimum,local_status,i
    logical :: accepted
    if(.not.c_associated(status_ptr))return
    call c_f_pointer(status_ptr,status);status=qf256_invalid_argument
    if(.not.c_associated(result_ptr))return
    call c_f_pointer(result_ptr,output);call clear_c_result(output)
    if(.not.c_associated(iq_ptr))return
    select case(sync_mode)
    case(qf256_sync_known);sync='known';minimum=qf256_frame_samples
    case(qf256_sync_blind);sync='blind';minimum=qf256_blind_min_samples
    case(qf256_sync_blind_hf);sync='blind-hf';minimum=qf256_blind_min_samples
    case default
      status=qf256_invalid_sync
      return
    end select
    if(ncomplex<minimum.or.ncomplex>qf256_max_samples)then
      status=qf256_invalid_length
      return
    end if
    call c_f_pointer(iq_ptr,input,[2*int(ncomplex)])
    allocate(iq(ncomplex))
    do i=1,ncomplex
      iq(i)=cmplx(real(input(2*i-1),real64),real(input(2*i),real64),real64)
    end do
    call qf256_decode(iq,sync,result,accepted,local_status)
    status=int(local_status,c_int32_t)
    if(local_status/=qf256_ok)return
    call fill_c_result(output,result,accepted)
  end subroutine qf256_rx_cf32

end module qf256_api
