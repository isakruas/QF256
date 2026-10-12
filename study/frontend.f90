! SPDX-License-Identifier: GPL-3.0-or-later
! Ideal 300..2700 Hz USB frontend, represented about a 1500 Hz centre.
module study_frontend_mod
  use numerics_mod, only: dp,rng_normal
  use waveform_metrics_mod, only: fft_forward
  implicit none
  private
  public :: frontend_capture
contains
  subroutine frontend_capture(signal,fs,n0,start,capture_samples,capture)
    complex(dp),intent(in) :: signal(:)
    real(dp),intent(in) :: fs,n0
    integer,intent(in) :: start,capture_samples
    complex(dp),allocatable,intent(out) :: capture(:)
    complex(dp),allocatable :: context(:)
    real(dp) :: frequency,sigma
    integer :: n,pad,i,signed_bin
    if(start<0.or.start+size(signal)>capture_samples.or.n0<0) error stop 'Invalid frontend input'
    n=1
    do while(n<2*capture_samples)
      n=2*n
    end do
    pad=(n-capture_samples)/2
    allocate(context(n),capture(capture_samples));sigma=sqrt(fs*n0/2)
    ! Noise exists outside both observation boundaries. The retained window
    ! is at least capture_samples/2 away from the periodic FFT seam.
    do i=1,n
      context(i)=sigma*cmplx(rng_normal(),rng_normal(),dp)
    end do
    context(pad+start+1:pad+start+size(signal))=context(pad+start+1:pad+start+size(signal))+signal
    call fft_forward(context)
    do i=1,n
      signed_bin=i-1
      if(signed_bin>n/2) signed_bin=signed_bin-n
      frequency=real(signed_bin,dp)*fs/n
      if(abs(frequency)>1200.0_dp) context(i)=0
    end do
    context=conjg(context);call fft_forward(context);context=conjg(context)/n
    capture=context(pad+1:pad+capture_samples)
  end subroutine frontend_capture
end module study_frontend_mod
