! SPDX-License-Identifier: GPL-3.0-or-later
program test_qf256_api
  use iso_fortran_env, only: real64
  use, intrinsic :: ieee_arithmetic, only: ieee_value,ieee_quiet_nan,ieee_is_finite
  use qf256_api
  implicit none
  integer :: bits(77),status,i
  complex(real64),allocatable :: iq(:),capture(:)
  type(sc_result) :: result
  logical :: accepted
  character(160) :: message
  if(qf256_api_version/=1.or.qf256_snr_reference_hz/=2500.0_real64.or. &
    qf256_blind_cfo_limit_hz/=750.0_real64.or.qf256_gate/=30.220758775848424_real64) &
    error stop 'Unexpected public API constants'
  do i=1,77
    bits(i)=modulo(i*17+i/3,2)
  end do
  call qf256_encode(bits,iq,status,message)
  if(status/=qf256_ok.or..not.allocated(iq))error stop 'Valid encoding failed'
  if(size(iq)/=qf256_frame_samples)error stop 'Wrong frame size'
  if(abs(sum(abs(iq)**2)/size(iq)-1.0_real64)>1e-12_real64)error stop 'Unexpected frame normalization'
  call qf256_decode(iq,'known',result,accepted,status,message)
  if(status/=qf256_ok.or..not.accepted.or.any(result%payload/=bits))error stop 'Known roundtrip failed'
  if(.not.result%snr_valid.or..not.ieee_is_finite(result%snr_2500_db))error stop 'Known roundtrip lacks valid SNR'
  call qf256_decode(iq,'blind',result,accepted,status,message)
  if(status/=qf256_invalid_length.or.accepted)error stop 'Short blind capture accepted'
  call qf256_decode(iq,'invalid',result,accepted,status,message)
  if(status/=qf256_invalid_sync.or.accepted)error stop 'Invalid synchronization accepted'
  if(result%snr_valid)error stop 'Invalid synchronization returned valid SNR'
  call qf256_decode(iq(:qf256_frame_samples-1),'known',result,accepted,status,message)
  if(status/=qf256_invalid_length.or.accepted)error stop 'Short known capture accepted'
  allocate(capture(qf256_max_samples+1));capture=0
  call qf256_decode(capture,'known',result,accepted,status,message)
  if(status/=qf256_invalid_length.or.accepted)error stop 'Oversized capture accepted'
  iq(1)=cmplx(ieee_value(0.0_real64,ieee_quiet_nan),0.0_real64,real64)
  call qf256_decode(iq,'known',result,accepted,status,message)
  if(status/=qf256_nonfinite.or.accepted)error stop 'NaN accepted'
  iq(1)=cmplx(1.0e95_real64,0.0_real64,real64)
  call qf256_decode(iq,'known',result,accepted,status,message)
  if(status/=qf256_numeric_range.or.accepted)error stop 'Extreme real64 input accepted'
  call qf256_encode(bits(:76),iq,status,message)
  if(status/=qf256_invalid_bits.or.allocated(iq))error stop 'Wrong bit count accepted'
  bits(1)=2
  call qf256_encode(bits,iq,status,message)
  if(status/=qf256_invalid_bits.or.allocated(iq))error stop 'Out-of-range bit accepted'
  print '(A)','PASS: Fortran API validation and known roundtrip'
end program test_qf256_api
