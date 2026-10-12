module study_tools
  use iso_fortran_env, only: real64
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
  implicit none
  integer,parameter :: dp=real64
  integer,parameter :: n_channels=3
  character(9),parameter :: cn(n_channels)=[character(9)::'quiet','moderate','disturbed']
  character(9),parameter :: ct(n_channels)=[character(9)::'Quiet','Moderate','Disturbed']
  real(dp),parameter :: gate=30.220758775848424_dp
contains
  subroutine require(ok,message)
    logical,intent(in)::ok
    character(*),intent(in)::message
    if(.not.ok)then
      print '(A)','ERROR: '//message
      error stop 1
    end if
  end subroutine
  subroutine fields(line,f,n)
    character(*),intent(in)::line
    character(*),intent(out)::f(:)
    integer,intent(out)::n
    integer::i,first
    f='';n=0;first=1
    do i=1,len_trim(line)+1
      if(i<=len_trim(line))then
        if(line(i:i)/=',')cycle
      end if
      n=n+1
      call require(n<=size(f),'Too many CSV fields')
      call require(i-first<=len(f(1)),'CSV field too long')
      f(n)=line(first:i-1);first=i+1
    end do
  end subroutine
  integer function iv(s)
    character(*),intent(in)::s
    integer::ios
    read(s,*,iostat=ios)iv
    call require(ios==0,'Invalid integer in CSV')
  end function
  real(dp) function rv(s)
    character(*),intent(in)::s
    integer::ios
    read(s,*,iostat=ios)rv
    call require(ios==0,'Invalid real in CSV')
    call require(ieee_is_finite(rv),'Nonfinite real in CSV')
  end function
  function it(i) result(s)
    integer,intent(in)::i
    character(32)::s
    write(s,'(I0)')i
  end function
  function rt(x) result(s)
    real(dp),intent(in)::x
    character(32)::s
    write(s,'(ES24.16E3)')x
    s=adjustl(s)
  end function
  function fixed(x,decimals) result(s)
    real(dp),intent(in)::x
    integer,intent(in)::decimals
    character(32)::s
    select case(decimals)
    case(1)
      write(s,'(F20.1)',round='nearest')x
    case(3)
      write(s,'(F20.3)',round='nearest')x
    case default
      call require(.false.,'Unsupported table precision')
    end select
    s=adjustl(s)
  end function
  function joined(f,n) result(s)
    character(*),intent(in)::f(:)
    integer,intent(in)::n
    character(:),allocatable::s
    integer::i
    s=trim(f(1))
    do i=2,n
      s=s//','//trim(f(i))
    end do
  end function
  subroutine wilson(k,n,lo,hi)
    integer,intent(in)::k,n
    real(dp),intent(out)::lo,hi
    real(dp),parameter::z=1.959963984540054_dp
    real(dp)::p,d,c,r
    p=real(k,dp)/n;d=1+z*z/n;c=(p+z*z/(2*n))/d
    r=z*sqrt(p*(1-p)/n+z*z/(4*real(n,dp)**2))/d
    lo=max(0.0_dp,c-r);hi=min(1.0_dp,c+r)
  end subroutine
  real(dp) function binomial_cdf(k,n,p) result(v)
    integer,intent(in)::k,n
    real(dp),intent(in)::p
    integer::i
    real(dp)::lp
    if(k<0)then
      v=0;return
    end if
    if(k>=n.or.p<=0)then
      v=1;return
    end if
    if(p>=1)then
      v=0;return
    end if
    v=0
    do i=0,k
      lp=log_gamma(real(n+1,dp))-log_gamma(real(i+1,dp))-log_gamma(real(n-i+1,dp))+ &
        i*log(p)+(n-i)*log(1-p)
      v=v+exp(lp)
    end do
    v=min(1.0_dp,v)
  end function
  real(dp) function cp_upper(k,n,alpha) result(v)
    integer,intent(in)::k,n
    real(dp),intent(in)::alpha
    real(dp)::lo,hi,mid
    integer::i
    if(k==n)then
      v=1;return
    end if
    if(k==0)then
      v=1-exp(log(alpha)/n);return
    end if
    lo=0;hi=1
    do i=1,80
      mid=(lo+hi)/2
      if(binomial_cdf(k,n,mid)>alpha)then
        lo=mid
      else
        hi=mid
      end if
    end do
    v=(lo+hi)/2
  end function
  real(dp) function cp_lower(k,n,alpha) result(v)
    integer,intent(in)::k,n
    real(dp),intent(in)::alpha
    v=1-cp_upper(n-k,n,alpha)
  end function
  subroutine sort_real(x)
    real(dp),intent(inout)::x(:)
    real(dp)::v
    integer::i,j
    do i=2,size(x)
      v=x(i);j=i-1
      do while(j>=1)
        if(x(j)<=v)exit
        x(j+1)=x(j);j=j-1
      end do
      x(j+1)=v
    end do
  end subroutine
end module

program analyze_qf256_study
  use study_tools
  implicit none
  character(4096)::mode,folder
  call get_command_argument(1,mode)
  call get_command_argument(2,folder)
  call require(len_trim(folder)>0,'Usage: analyze summarize DIRECTORY')
  select case(trim(mode))
  case('summarize')
    call require(command_argument_count()==2,'Summary takes only the study directory')
    call summarize(trim(folder))
  case default
    call require(.false.,'Unknown analysis operation')
  end select
contains

  subroutine summarize(dir)
    character(*),intent(in)::dir
    character(8192)::line
    character(128)::f(64),o(24)
    character(7),parameter::pn(2)=[character(7)::'average','peak']
    character(11),parameter::ln(2)=[character(11)::'diagnostic','independent']
    character(20),allocatable::message(:,:,:,:)
    integer::seen(128,6,n_channels,2),success(6,n_channels,2),accept(6,n_channels,2),wrong(6,n_channels,2)
    integer::seeds(3,128,6,n_channels,2),noise_seen(4096,2),noise_seeds(4096,2),noise_n(0:6,2)
    integer::noise_raw(0:6,2),noise_accept(0:6,2),noise_exceed(0:6,2)
    real(dp),allocatable::truth(:,:,:,:,:)
    real(dp)::evidence_cal(2048)
    integer::u,v,brief,threshold_file,agg,n,ios,row,c,p,pt,t,k,a,w,j,sid,srow,condition
    integer::lot,g,base,np,nraw,ngated,nexceed,enabled,expected_seed,tot,total_wrong,total_accept
    integer::source_rows(2*n_channels+4),noise_enabled,threshold_lo,threshold_hi
    real(dp)::snr,lo,hi,mlo,mhi,wlo,whi,estimated_gate,frac,qlo(6),qhi(6),crossing
    real(dp)::probs(6),variance,evidence,upper
    allocate(message(128,6,n_channels,2),truth(2,128,6,n_channels,2))
    seen=0;success=0;accept=0;wrong=0;source_rows=0
    open(newunit=u,file=dir//'/confirmation.csv',status='old')
    read(u,'(A)')line;row=0
    do
      read(u,'(A)',iostat=ios)line
      if(ios<0)exit
      call require(ios==0,'Normalized signal read failure')
      call fields(line,f,n);call require(n==26,'Normalized signal column count')
      row=row+1;sid=iv(f(1)(2:));srow=iv(f(2))
      call require(sid>=1.and.sid<=2*n_channels,'Invalid signal source ID')
      source_rows(sid)=source_rows(sid)+1
      call require(srow==source_rows(sid),'Signal source rows are not contiguous')
      c=0;p=0
      do j=1,n_channels
        if(f(3)==cn(j))c=j
      end do
      do j=1,2
        if(f(4)==pn(j))p=j
      end do
      call require(c>0.and.p>0,'Unknown signal condition')
      snr=rv(f(5));pt=nint((snr+26)/2);t=iv(f(6))
      call require(pt>=1.and.pt<=6.and.t>=1.and.t<=128,'Signal index outside fixed grid')
      call require(abs(snr-(-26+2*pt))<1e-12_dp,'Off-grid signal SNR')
      call require(sid==(p-1)*n_channels+c.and.srow==(pt-1)*128+t,'Signal source mapping mismatch')
      seen(t,pt,c,p)=seen(t,pt,c,p)+1
      condition=c*6+pt
      seeds(:,t,pt,c,p)=[iv(f(7)),iv(f(8)),iv(f(9))]
      call require(all(seeds(:,t,pt,c,p)==[20271011,120271011,220271011]+[condition*100003+t*101, &
        condition*200003+t*307,condition*300007+t*911]),'Signal seed formula mismatch')
      message(t,pt,c,p)=f(10)(:20)
      call require(len_trim(f(10))==20,'Message token must contain 20 hex digits')
      call require(index('01',f(10)(1:1))>0,'Message token exceeds 77 bits')
      do j=1,len_trim(f(10))
        call require(index('0123456789ABCDEF',f(10)(j:j))>0,'Invalid message token')
      end do
      k=iv(f(11));a=iv(f(12));w=iv(f(13))
      call require(min(k,a,w)>=0.and.max(k,a,w)<=1.and.a==k+w,'Invalid signal outcome')
      success(pt,c,p)=success(pt,c,p)+k;accept(pt,c,p)=accept(pt,c,p)+a;wrong(pt,c,p)=wrong(pt,c,p)+w
      evidence=rv(f(26));call require(a==0.or.evidence>=gate,'Accepted signal below gate')
      j=iv(f(25));call require(j>=1.and.j<=100,'Signal iteration count')
      snr=rv(f(21));call require(snr>=.4_dp.and.snr<=.6_dp,'Signal true timing bounds')
      call require(abs(rv(f(23)))<=2.0_dp,'Signal true frequency bounds')
      snr=rv(f(22));call require(snr>=.3_dp.and.snr<=.7_dp,'Signal estimated timing bounds')
      call require(abs(rv(f(24)))<=125.0_dp,'Signal estimated frequency bounds')
      truth(:,t,pt,c,p)=[rv(f(21)),rv(f(23))]
    end do
    close(u)
    call require(row==4608.and.all(seen==1),'Missing or duplicate signal grid records')
    call require(all(seeds(:,:,:,:,1)==seeds(:,:,:,:,2)).and. &
      all(message(:,:,:,1)==message(:,:,:,2)),'Power constraints must have paired source cases')
    call require(maxval(abs(truth(:,:,:,:,1)-truth(:,:,:,:,2)))<1e-12_dp,'Paired channel offsets disagree')

    open(newunit=brief,file=dir//'/RESULTS.txt',status='replace')
    write(brief,'(A)')'QF256 completed-record analysis'
    write(brief,'(A)')'4608 signal records: 2304 source/channel/noise cases paired across two power constraints.'
    write(brief,'(A)')'36 channel/power/SNR cells, 128 records each; SNR grid -24,-22,-20,-18,-16,-14 dB.'
    write(brief,'(A)')'Correct accepted means all source bits recovered and operational acceptance passed.'
    write(brief,'(A)')'Missed means no accepted message; accepted wrong is reported separately.'
    open(newunit=v,file=dir//'/cells.csv',status='replace')
    write(v,'(A)')'channel,power_constraint,snr_reference_db,n,correct_accepted,missed,accepted_wrong,correct_rate,wilson95_low,wilson95_high,missed_rate,missed_wilson95_low,missed_wilson95_high,wrong_rate,wrong_wilson95_low,wrong_wilson95_high'
    do p=1,2
      do c=1,n_channels
        do pt=1,6
          k=success(pt,c,p);a=accept(pt,c,p);w=wrong(pt,c,p)
          call wilson(k,128,lo,hi);call wilson(128-a,128,mlo,mhi);call wilson(w,128,wlo,whi)
          o='';o(1)=cn(c);o(2)=pn(p);o(3)=it(-26+2*pt);o(4)='128'
          o(5)=it(k);o(6)=it(128-a);o(7)=it(w);o(8)=rt(real(k,dp)/128)
          o(9)=rt(lo);o(10)=rt(hi);o(11)=rt(real(128-a,dp)/128);o(12)=rt(mlo);o(13)=rt(mhi)
          o(14)=rt(real(w,dp)/128);o(15)=rt(wlo);o(16)=rt(whi)
          write(v,'(A)')joined(o,16)
        end do
      end do
    end do
    close(v)
    open(newunit=agg,file=dir//'/aggregate.csv',status='replace')
    write(agg,'(A)')'channel,power_constraint,records,correct_accepted,missed,accepted_wrong,correct_fraction,interpretation'
    do p=1,2
      do c=1,n_channels+1
        if(c<=n_channels)then
          tot=sum(success(:,c,p));total_accept=sum(accept(:,c,p));total_wrong=sum(wrong(:,c,p));np=768;o(1)=cn(min(c,n_channels))
        else
          tot=sum(success(:,:,p));total_accept=sum(accept(:,:,p));total_wrong=sum(wrong(:,:,p));np=2304;o(1)='all'
        end if
        o(2)=pn(p);o(3)=it(np);o(4)=it(tot);o(5)=it(np-total_accept);o(6)=it(total_wrong)
        o(7)=rt(real(tot,dp)/np);o(8)='equal_weight_fixed_grid_summary'
        write(agg,'(A)')joined(o,8)
        write(brief,'(A,1X,A,1X,I0,A,I0,A,I0,A,I0)')trim(o(1)),trim(pn(p)),tot,'/',np, &
          ' correct; missed=',np-total_accept,'; accepted wrong=',total_wrong
      end do
    end do
    o(1)='all';o(2)='both_paired';o(3)='4608';o(4)=it(sum(success));o(5)=it(4608-sum(accept))
    o(6)=it(sum(wrong));o(7)=rt(real(sum(success),dp)/4608);o(8)='paired_record_count_not_independent_trials'
    write(agg,'(A)')joined(o,8);close(agg)

    open(newunit=threshold_file,file=dir//'/thresholds.csv',status='replace')
    write(threshold_file,'(A)')'channel,power_constraint,linear_50pct_crossing_db,interpolation_left_db,interpolation_right_db,simultaneous95_grid_lower_db,simultaneous95_grid_upper_db,interval_method'
    do p=1,2
      do c=1,n_channels
        probs=real(success(:,c,p),dp)/128
        call require(all(probs(2:)>=probs(:5)),'Observed curve is not monotone')
        j=0
        do pt=1,5
          if(probs(pt)<.5_dp.and.probs(pt+1)>=.5_dp)j=pt
        end do
        call require(j>0,'No 50 percent crossing in observed grid')
        crossing=-26+2*j+2*(.5_dp-probs(j))/(probs(j+1)-probs(j))
        threshold_lo=-99;threshold_hi=99
        do pt=1,6
          qlo(pt)=cp_lower(success(pt,c,p),128,.05_dp/(2*6))
          qhi(pt)=cp_upper(success(pt,c,p),128,.05_dp/(2*6))
          if(qhi(pt)<.5_dp)threshold_lo=-26+2*pt
          if(qlo(pt)>.5_dp.and.threshold_hi==99)threshold_hi=-26+2*pt
        end do
        call require(threshold_lo/=-99.and.threshold_hi/=99,'Threshold bracket is grid censored')
        o(1)=cn(c);o(2)=pn(p);o(3)=rt(crossing);o(4)=it(-26+2*j);o(5)=it(-24+2*j)
        o(6)=it(threshold_lo);o(7)=it(threshold_hi);o(8)='Bonferroni_exact_binomial_6_knots_monotone_response'
        write(threshold_file,'(A)')joined(o,8)
        write(brief,'(A,1X,A,A,F10.5,A,I0,A,I0,A)')trim(cn(c)),trim(pn(p)), &
          ' interpolated 50%=',crossing,' dB; simultaneous 95% grid bracket [',threshold_lo,',',threshold_hi,'] dB'
      end do
    end do
    close(threshold_file)

    noise_seen=0;noise_seeds=0;noise_n=0;noise_raw=0;noise_accept=0;noise_exceed=0
    open(newunit=u,file=dir//'/noise.csv',status='old');read(u,'(A)')line;row=0
    do
      read(u,'(A)',iostat=ios)line
      if(ios<0)exit
      call require(ios==0,'Normalized noise read failure')
      call fields(line,f,n);call require(n==19,'Normalized noise column count')
      row=row+1;sid=iv(f(1)(2:));srow=iv(f(2))
      call require(sid>=2*n_channels+1.and.sid<=2*n_channels+4,'Invalid noise source ID')
      source_rows(sid)=source_rows(sid)+1
      call require(srow==source_rows(sid),'Noise source rows are not contiguous')
      lot=0
      do j=1,2
        if(f(3)==ln(j))lot=j
      end do
      call require(lot>0,'Unknown noise lot')
      np=2048;base=40271011;enabled=1
      if(lot==2)then
        np=4096;base=60271011;enabled=1
      end if
      g=iv(f(4));pt=iv(f(5));t=iv(f(6));snr=rv(f(7))
      call require(g>=1.and.g<=np,'Noise index out of bounds')
      call require(sid==2*n_channels+2*(lot-1)+1+(g-1)/(np/2).and. &
        srow==modulo(g-1,np/2)+1,'Noise source mapping mismatch')
      call require(pt==modulo(g-1,6)+1.and.t==(g-1)/6+1,'Noise cyclic grid mismatch')
      call require(abs(snr-(-26+2*pt))<1e-12_dp,'Noise reference scale mismatch')
      expected_seed=base+pt*300007+t*911+29
      noise_seeds(g,lot)=iv(f(8));call require(noise_seeds(g,lot)==expected_seed,'Noise seed mismatch')
      noise_seen(g,lot)=noise_seen(g,lot)+1
      nraw=iv(f(9));a=iv(f(10));evidence=rv(f(11));w=iv(f(12));noise_enabled=iv(f(18))
      call require(min(nraw,a,w)>=0.and.max(nraw,a,w)<=1.and.noise_enabled==enabled,'Noise flags mismatch')
      if(lot==1)evidence_cal(g)=evidence
      call require(abs(rv(f(19))-gate)<1e-12_dp,'Fixed project gate mismatch')
      call require(a==merge(1,0,nraw==1.and.evidence>=gate),'Noise acceptance mismatch')
      call require(w==a,'Noise false-message/event mismatch')
      variance=12000/(2500*10.0_dp**(snr/10))
      call require(abs(rv(f(13))/variance-1)<1e-12_dp,'Noise scale mismatch')
      call require(rv(f(14))>0,'Nonpositive estimated noise variance')
      snr=rv(f(15));call require(snr>=.3_dp.and.snr<=.7_dp,'Noise timing bounds')
      call require(abs(rv(f(16)))<=125,'Noise frequency bounds')
      j=iv(f(17));call require(j>=1.and.j<=100,'Noise iteration bound')
      ngated=merge(1,0,nraw==1.and.evidence>=gate);nexceed=merge(1,0,evidence>=gate)
      do j=0,6
        if(j/=0.and.j/=pt)cycle
        noise_n(j,lot)=noise_n(j,lot)+1;noise_raw(j,lot)=noise_raw(j,lot)+nraw
        noise_accept(j,lot)=noise_accept(j,lot)+ngated;noise_exceed(j,lot)=noise_exceed(j,lot)+nexceed
      end do
    end do
    close(u)
    call require(row==6144.and.all(noise_seen(:2048,1)==1).and.all(noise_seen(:,2)==1), &
      'Missing or duplicate noise records')
    call require(all(source_rows(:6)==768).and.all(source_rows(7:8)==1024).and. &
      all(source_rows(9:10)==2048),'Source row counts disagree')
    do g=1,2048
      call require(.not.any(noise_seeds(:,2)==noise_seeds(g,1)),'Diagnostic and independent seeds overlap')
    end do
    call sort_real(evidence_cal);frac=.99_dp*(2048-1)+1
    j=int(frac);frac=frac-j;estimated_gate=(1-frac)*evidence_cal(j)+frac*evidence_cal(j+1)
    open(newunit=v,file=dir//'/noise_summary.csv',status='replace')
    write(v,'(A)')'lot,point,reference_scale_db,captures,raw_fec_events,gated_false_events,evidence_exceedances,gate,independent_one_sided95_exact_upper'
    do lot=1,2
      do pt=0,6
        o='';o(1)=ln(lot);o(2)=it(pt);o(3)='all'
        if(pt>0)o(3)=it(-26+2*pt)
        o(4)=it(noise_n(pt,lot));o(5)=it(noise_raw(pt,lot));o(6)=it(noise_accept(pt,lot))
        o(7)=it(noise_exceed(pt,lot));o(8)=rt(gate);o(9)='NA_diagnostic'
        if(lot==2)o(9)=rt(cp_upper(noise_accept(pt,lot),noise_n(pt,lot),.05_dp))
        write(v,'(A)')joined(o,9)
      end do
    end do
    close(v)
    upper=cp_upper(noise_accept(0,2),4096,.05_dp)
    write(brief,'(A,ES24.16)')'Fixed project acceptance gate (not fitted in this campaign): ',gate
    write(brief,'(A,ES24.16)')'Diagnostic evidence type7 99th percentile (not a replacement gate): ',estimated_gate
    do lot=1,2
      write(brief,'(A,A,I0,A,I0,A,I0,A,I0)')trim(ln(lot)),': captures=',noise_n(0,lot), &
        '; raw FEC=',noise_raw(0,lot),'; gated events=',noise_accept(0,lot),'; evidence exceedances=',noise_exceed(0,lot)
    end do
    write(brief,'(A,ES24.16)')'Independent one-sided exact 95% upper per 15-second capture: ',upper
    write(brief,'(A)')'This total bound assumes a common event probability.'
    if(noise_accept(0,2)==0)write(brief,'(A)')'For zero events it is also conservative for an allocation-weighted mean if noise-scale probabilities differ.'
    if(sum(noise_raw)==0)write(brief,'(A)')'Zero raw FEC events means these records do not measure an observed reduction caused by the gate.'
    write(brief,'(A)')'Threshold point estimates interpolate the observed 2 dB grid; grid brackets assume a monotone true response.'
    write(brief,'(A)')'Each bracket uses six simultaneous exact binomial intervals (Bonferroni, 95% coverage per curve).'
    write(brief,'(A)')'Grid aggregates are descriptive; paired power records are not independent additional trials.'
    write(brief,'(A)')'All outputs were computed from completed records. No waveform, channel or noise simulation was executed.'
    close(brief)
    call publication_tables(dir)
    print '(A)','Validated 4608 signal records, 2304 paired cases and 6144 distinct-lot noise records.'
    print '(A,I0,A,I0,A)','Correct accepted totals: average=',sum(success(:,:,1)),', peak=',sum(success(:,:,2)),'.'
    print '(A,ES24.16)','Independent noise upper95=',upper
  end subroutine

  subroutine publication_tables(dir)
    character(*),intent(in)::dir
    character(8192)::line
    character(128)::f(24)
    character(7),parameter::pn(2)=[character(7)::'average','peak']
    character(7),parameter::ptitle(2)=[character(7)::'Average','Peak']
    character(15),parameter::macro_name(2)=[character(15)::'QFcellsAverage','QFcellsPeak']
    character(:),allocatable::table_line
    integer::u,v,n,ios,c,p,point,j,counts(6,n_channels,2),seen(6,n_channels,2)
    real(dp)::rates(6,n_channels,2),lower(6,n_channels,2),upper(6,n_channels,2)
    seen=0
    open(newunit=u,file=dir//'/cells.csv',status='old',action='read')
    read(u,'(A)')line
    do
      read(u,'(A)',iostat=ios)line
      if(ios<0)exit
      call require(ios==0,'Publication cell CSV read failure')
      call fields(line,f,n);call require(n==16,'Publication cell CSV column count')
      c=0;p=0
      do j=1,n_channels
        if(f(1)==cn(j))c=j
      end do
      do j=1,2
        if(f(2)==pn(j))p=j
      end do
      point=(iv(f(3))+26)/2
      call require(c>0.and.p>0.and.point>=1.and.point<=6,'Publication cell condition')
      seen(point,c,p)=seen(point,c,p)+1
      counts(point,c,p)=iv(f(5));rates(point,c,p)=rv(f(8))
      lower(point,c,p)=rv(f(9));upper(point,c,p)=rv(f(10))
    end do
    close(u);call require(all(seen==1),'Publication cell completeness')
    open(newunit=v,file=dir//'/publication-cells.tex',status='replace')
    do p=1,2
      write(v,'(A)')'\newcommand{\'//trim(macro_name(p))//'}{%'
      write(v,'(A)')'\begin{tabular}{@{}lrrrl@{}}'
      write(v,'(A)')'\toprule'
      write(v,'(A)')'Profile & Reference $\rho$ & $k/128$ & Rate & 95\% CI \\'
      write(v,'(A)')'\midrule'
      do c=1,n_channels
        do point=1,6
          table_line=trim(ct(c))//' & $'//trim(it(-26+2*point))//'$\,dB'
          table_line=table_line//' & '//trim(it(counts(point,c,p)))//'/128 & '// &
            trim(fixed(rates(point,c,p),3))//' & ['//trim(fixed(lower(point,c,p),3))//', '// &
            trim(fixed(upper(point,c,p),3))//']'
          write(v,'(A)')table_line//' \\'
        end do
      end do
      write(v,'(A)')'\bottomrule'
      write(v,'(A)')'\end{tabular}}'
    end do
    close(v)
    open(newunit=u,file=dir//'/thresholds.csv',status='old',action='read')
    read(u,'(A)')line
    open(newunit=v,file=dir//'/publication-thresholds.tex',status='replace')
    write(v,'(A)')'\begin{tabular}{@{}llcc@{}}\toprule'
    write(v,'(A)')'Profile & Power setting & 50\% crossing & 95\% grid bracket \\'
    write(v,'(A)')'\midrule'
    do
      read(u,'(A)',iostat=ios)line
      if(ios<0)exit
      call require(ios==0,'Publication threshold CSV read failure')
      call fields(line,f,n);call require(n==8,'Publication threshold CSV column count')
      c=0;p=0
      do j=1,n_channels
        if(f(1)==cn(j))c=j
      end do
      do j=1,2
        if(f(2)==pn(j))p=j
      end do
      call require(c>0.and.p>0,'Publication threshold condition')
      write(v,'(A)')trim(ct(c))//' & '//trim(ptitle(p))//' & $'//trim(fixed(rv(f(3)),1))// &
        '$\,dB & $['//trim(f(6))//', '//trim(f(7))//']$\,dB \\'
    end do
    write(v,'(A)')'\bottomrule\end{tabular}'
    close(u);close(v)
  end subroutine
end program
