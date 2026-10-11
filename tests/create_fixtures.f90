! One-time snapshot utility. Normal tests never update their expected values.
program create_fixtures
  use iso_fortran_env, only: real32
  use numerics_mod, only: dp
  use qra_soft_mod, only: qra_encode
  use mfsk_iq_mod, only: sc_config,setup_sc,sc_tx
  implicit none
  character(77), parameter :: source_bits= &
    '00000010010001101000101011001111000100110101011110011011110111100000001101000'
  type(sc_config) :: cfg
  integer :: payload(77),word(65),i,u
  integer, parameter :: indices(36)=[1,2,16,31,32,33,34,63,64,65,127,512,1024,1535,1536,1537,1567,1568,1569, &
    3072,3104,4608,6176,16384,32768,49152,65536,81920,98304,114688,116735,116736,116737,116768,116799,116800]
  complex(dp), allocatable :: iq(:)
  real(real32), allocatable :: packed(:,:)
  do i=1,77
    payload(i)=iachar(source_bits(i:i))-iachar('0')
  end do
  call setup_sc(5,10.0_dp,12000.0_dp,cfg)
  call qra_encode(payload,cfg%code,word)
  call sc_tx(payload,cfg,iq)
  open(newunit=u,file='tests/fixtures/payload77.txt',status='new')
  write(u,'(A)') source_bits; close(u)
  open(newunit=u,file='tests/fixtures/codeword65.txt',status='new')
  write(u,'(*(I0,1X))') word; close(u)
  open(newunit=u,file='tests/fixtures/iq_subset.txt',status='new')
  write(u,'(I0)') size(indices)
  do i=1,size(indices)
    write(u,'(I0,1X,ES26.18,1X,ES26.18)') indices(i),real(iq(indices(i)),dp),aimag(iq(indices(i)))
  end do
  close(u)
  allocate(packed(2,size(iq))); packed(1,:)=real(iq,real32); packed(2,:)=real(aimag(iq),real32)
  open(newunit=u,file='build/test/core_fixture.cf32',access='stream',form='unformatted',status='replace')
  write(u) packed; close(u)
  print '(A)','QF256 fixtures created. Freeze text files and record the full raw-IQ SHA256.'
end program
