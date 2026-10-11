! SPDX-License-Identifier: GPL-3.0-or-later
! Descriptive analysis of completed measurements; no waveform generation.
program summarize_physical
  use, intrinsic :: iso_fortran_env, only: real64
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
  implicit none
  integer, parameter :: dp=real64, count=1536
  real(dp), parameter :: snrs(6)=[-24.0_dp,-22.0_dp,-20.0_dp,-18.0_dp,-16.0_dp,-14.0_dp]
  real(dp) :: values(10,count,2), record(10), snr, ordered(count), fraction
  logical :: seen(count,2)
  character(4096) :: line
  character(18) :: source, sources(count,2)
  character(12) :: constraint
  character(12), parameter :: constraints(2)=[character(12)::'average','peak']
  integer :: input, output, ios, channel_id, trial, point, power, row, rows, pseed, cseed, nseed
  integer :: condition, k, metric
  character(5), parameter :: metrics(2)=[character(5)::'bw99','papr']
  integer, parameter :: columns(2)=[5,4]
  seen=.false.; rows=0
  open(newunit=input,file='study/physical/confirmation_physical.csv',status='old',action='read')
  read(input,'(A)',iostat=ios) line
  if(ios/=0.or.index(line,'channel_id,constraint,snr_db,trial,')/=1) error stop 'Unexpected physical header'
  do
    read(input,'(A)',iostat=ios) line
    if(ios<0) exit
    if(ios/=0) error stop 'Cannot read physical row'
    read(line,*,iostat=ios) channel_id,constraint,snr,trial,pseed,cseed,nseed,source,record
    if(ios/=0) error stop 'Malformed physical row'
    if(channel_id/=3.and.channel_id/=4) error stop 'Unexpected channel'
    if(trial<1.or.trial>128) error stop 'Unexpected trial'
    point=0
    do k=1,6
      if(abs(snr-snrs(k))<1e-10_dp) point=k
    end do
    if(point==0) error stop 'Unexpected SNR point'
    power=0
    do k=1,2
      if(constraint==constraints(k)) power=k
    end do
    if(power==0) error stop 'Unexpected power constraint'
    condition=(channel_id-1)*6+point
    if(pseed/=20261201+condition*100003+trial*101) error stop 'Unexpected payload seed'
    if(cseed/=20261201+condition*200003+trial*307) error stop 'Unexpected channel seed'
    if(nseed/=20261201+condition*300007+trial*911) error stop 'Unexpected noise seed'
    row=(channel_id-3)*768+(point-1)*128+trial
    if(seen(row,power)) error stop 'Duplicate physical key'
    if(any(.not.ieee_is_finite(record))) error stop 'Nonfinite physical value'
    if(any(record(1:3)<=0.0_dp)) error stop 'Nonpositive power or energy'
    values(:,row,power)=record; sources(row,power)=source; seen(row,power)=.true.; rows=rows+1
  end do
  close(input)
  if(rows/=2*count.or..not.all(seen)) error stop 'Incomplete physical table'
  if(any(sources(:,1)/=sources(:,2))) error stop 'Power constraints have different source cases'
  if(maxval(abs(values(4:5,:,1)-values(4:5,:,2)))>1e-10_dp) error stop 'Power constraint changed PAPR or bandwidth'
  if(maxval(abs(values(9:10,:,1)-values(9:10,:,2)))>1e-10_dp) error stop 'Power constraint changed start or CFO'
  if(maxval(abs(values(1,:,1)-1.0_dp))>1e-8_dp) error stop 'Average constraint is not normalized'
  if(maxval(abs(values(2,:,2)-1.0_dp))>1e-10_dp) error stop 'Peak constraint is not normalized'
  if(maxval(abs(values(1,:,2)-values(1,:,1)/values(2,:,1)))>1e-10_dp) error stop 'Peak average-power scaling mismatch'
  if(maxval(abs(values(3,:,2)-values(3,:,1)/values(2,:,1)))>1e-10_dp) error stop 'Peak energy scaling mismatch'
  open(newunit=output,file='study/physical/summary.csv',status='replace',action='write')
  write(output,'(A)') 'constraint,trials,min_bw99_hz,mean_bw99_hz,max_bw99_hz,min_papr_db,mean_papr_db,max_papr_db,'// &
    'min_average_power,mean_average_power,max_average_power,min_energy,mean_energy,max_energy,'// &
    'min_peak_power,mean_peak_power,max_peak_power'
  do power=1,2
    write(output,'(*(G0,:,","))') trim(constraints(power)),count, &
      minval(values(5,:,power)),sum(values(5,:,power))/count,maxval(values(5,:,power)), &
      minval(values(4,:,power)),sum(values(4,:,power))/count,maxval(values(4,:,power)), &
      minval(values(1,:,power)),sum(values(1,:,power))/count,maxval(values(1,:,power)), &
      minval(values(3,:,power)),sum(values(3,:,power))/count,maxval(values(3,:,power)), &
      minval(values(2,:,power)),sum(values(2,:,power))/count,maxval(values(2,:,power))
  end do
  close(output)
  do metric=1,2
    ordered=values(columns(metric),:,1); call sort_values(ordered)
    open(newunit=output,file='study/physical/'//trim(metrics(metric))//'_cdf.csv',status='replace',action='write')
    write(output,'(A)') 'value,proportion'
    do row=1,count
      fraction=real(row,dp)/count
      write(output,'(*(G0,:,","))') ordered(row),fraction
    end do
    close(output)
  end do
  print '(A)', 'Validated 3072 rows; summarized 1536 unique source cases across both power constraints.'
contains
  subroutine sort_values(array)
    real(dp), intent(inout) :: array(:)
    real(dp) :: value
    integer :: i,j
    do i=2,size(array)
      value=array(i); j=i-1
      do while(j>=1)
        if(array(j)<=value) exit
        array(j+1)=array(j); j=j-1
      end do
      array(j+1)=value
    end do
  end subroutine sort_values
end program summarize_physical
