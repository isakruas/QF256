! SPDX-License-Identifier: GPL-3.0-or-later
! GF64 graph/weights: Q65 qra15_65_64_irr_e23, Nico Palermo (2020).
! Fortran sum-product decoder with Walsh-Hadamard GF convolution.
! GF256 uses the numeric GF64 coefficient values, not their GF64 logarithms.
! The three zero information symbols are shortened.
module qra_soft_mod
  use numerics_mod, only: dp
  implicit none
  private
  public :: qra_config,qra_setup,qra_encode,qra_decode,qra_syndrome,qra_metric
  integer,parameter :: nv=65,nc=51,ne=151
  integer,parameter :: accumulator_input(51)=[ &
    14,2,4,5,9,13,10,15,11,6,1,8,2,12,9,10,13,7,4,11,8,6,3,14,13,5,9,1,2,12, &
    3,10,15,6,7,14,8,13,12,3,10,1,11,5,8,15,9,12,4,7,11]
  integer,parameter :: official_weight_log(51)=[ &
    0,14,0,0,13,37,0,27,56,62,29,0,52,34,62,4,3,22,25,0,22,0,20,10,0,43,53,60,0,0, &
    0,62,0,5,0,61,36,31,61,59,10,0,29,39,25,18,0,14,11,50,17]
  type qra_config
    integer :: bits,q,ntransmitted,nsync,nsymbols
    integer :: weights(51),check_degree(nc),check_edge(3,nc)
    integer :: variable_degree(nv),variable_edge(4,nv),edge_variable(ne),edge_weight(ne)
    integer,allocatable :: gf_log(:),gf_exp(:),permutation(:,:),transmitted(:)
  end type qra_config
contains
  subroutine qra_setup(bits,cfg)
    integer,intent(in) :: bits
    type(qra_config),intent(out) :: cfg
    integer :: gf64exp(0:62),value,i,j,e,poly,v,total_weights(15)
    if(bits/=6.and.bits/=8) error stop 'QRA field size must be 6 or 8 bits'
    cfg%bits=bits;cfg%q=2**bits
    cfg%ntransmitted=63;cfg%nsync=22
    if(bits==8)then
      cfg%ntransmitted=60;cfg%nsync=16
    end if
    cfg%nsymbols=cfg%ntransmitted+cfg%nsync
    allocate(cfg%gf_log(0:cfg%q-1),cfg%gf_exp(0:cfg%q-2))
    allocate(cfg%permutation(0:cfg%q-1,ne),cfg%transmitted(cfg%ntransmitted))
    poly=int(z'43');if(bits==8)poly=int(z'11D')
    value=1;cfg%gf_log=-1
    do i=0,cfg%q-2
      if(cfg%gf_log(value)/=-1)error stop 'Polynomial is not primitive'
      cfg%gf_exp(i)=value;cfg%gf_log(value)=i
      value=ishft(value,1)
      if(btest(value,bits))value=ieor(value,poly)
    end do
    if(value/=1)error stop 'Invalid field cycle'
    value=1
    do i=0,62
      gf64exp(i)=value;value=ishft(value,1)
      if(btest(value,6))value=ieor(value,int(z'43'))
    end do
    cfg%weights=gf64exp(official_weight_log)
    total_weights=0
    do i=1,nc
      v=accumulator_input(i)
      total_weights(v)=ieor(total_weights(v),cfg%weights(i))
    end do
    if(any(total_weights/=0))error stop 'QRA accumulator does not terminate identically'
    cfg%check_degree=0;cfg%check_edge=0;cfg%variable_degree=0;cfg%variable_edge=0;e=0
    do i=1,nc
      call add_edge(i,accumulator_input(i),cfg%weights(i))
      if(i<=50)call add_edge(i,15+i,1)
      if(i>1)call add_edge(i,14+i,1)
    end do
    if(e/=ne)error stop 'Wrong graph edge count'
    do e=1,ne
      do i=0,cfg%q-1
        cfg%permutation(i,e)=gf_multiply(cfg,cfg%edge_weight(e),i)
      end do
    end do
    j=13;if(bits==8)j=10
    do i=1,j
      cfg%transmitted(i)=i
    end do
    do i=1,50
      cfg%transmitted(j+i)=15+i
    end do
  contains
    subroutine add_edge(check,variable,weight)
      integer,intent(in) :: check,variable,weight
      e=e+1
      cfg%check_degree(check)=cfg%check_degree(check)+1
      cfg%check_edge(cfg%check_degree(check),check)=e
      cfg%variable_degree(variable)=cfg%variable_degree(variable)+1
      if(cfg%variable_degree(variable)>4)error stop 'Variable degree exceeds graph allocation'
      cfg%variable_edge(cfg%variable_degree(variable),variable)=e
      cfg%edge_variable(e)=variable;cfg%edge_weight(e)=weight
    end subroutine add_edge
  end subroutine qra_setup

  integer function gf_multiply(cfg,a,b) result(c)
    type(qra_config),intent(in) :: cfg
    integer,intent(in) :: a,b
    c=0
    if(a/=0.and.b/=0)c=cfg%gf_exp(modulo(cfg%gf_log(a)+cfg%gf_log(b),cfg%q-1))
  end function gf_multiply

  subroutine add_crc(cfg,message)
    type(qra_config),intent(in) :: cfg
    integer,intent(inout) :: message(15)
    integer :: crc,i,j,t,bit
    if(cfg%bits==6)then
      ! Q65 reflected CRC12, processing each six-bit symbol LSB first.
      crc=0
      do i=1,13
        t=message(i)
        do j=1,6
          bit=iand(ieor(t,crc),1);crc=ishft(crc,-1)
          if(bit/=0)crc=ieor(crc,int(z'F01'))
          t=ishft(t,-1)
        end do
      end do
      message(14)=iand(crc,63);message(15)=ishft(crc,-6)
    else
      ! CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection/xorout,
      ! over ten bytes containing 77 source bits followed by three public zeros.
      crc=int(z'FFFF')
      do i=1,10
        do j=7,0,-1
          bit=ieor(ibits(crc,15,1),ibits(message(i),j,1))
          crc=iand(ishft(crc,1),int(z'FFFF'))
          if(bit/=0)crc=ieor(crc,int(z'1021'))
        end do
      end do
      message(14)=ishft(crc,-8);message(15)=iand(crc,255)
    end if
  end subroutine add_crc

  subroutine qra_encode(payload,cfg,word)
    integer,intent(in) :: payload(77)
    type(qra_config),intent(in) :: cfg
    integer,intent(out) :: word(65)
    integer :: message(15),i,j,k,accumulator
    if(any(payload<0.or.payload>1))error stop 'Payload must contain exactly 77 binary bits'
    message=0
    do k=1,77
      i=(k-1)/cfg%bits+1;j=cfg%bits-1-modulo(k-1,cfg%bits)
      message(i)=ior(message(i),ishft(payload(k),j))
    end do
    call add_crc(cfg,message)
    word(:15)=message;accumulator=0
    do i=1,50
      accumulator=ieor(accumulator,gf_multiply(cfg,cfg%weights(i),message(accumulator_input(i))))
      word(15+i)=accumulator
    end do
    if(qra_syndrome(word,cfg)/=0)error stop 'Internal QRA encode/check mismatch'
  end subroutine qra_encode

  integer function qra_syndrome(word,cfg) result(failed)
    integer,intent(in) :: word(65)
    type(qra_config),intent(in) :: cfg
    integer :: c,j,e,parity
    failed=0
    do c=1,nc
      parity=0
      do j=1,cfg%check_degree(c)
        e=cfg%check_edge(j,c)
        parity=ieor(parity,gf_multiply(cfg,cfg%edge_weight(e),word(cfg%edge_variable(e))))
      end do
      if(parity/=0)failed=failed+1
    end do
  end function qra_syndrome

  subroutine fwht(a)
    real(dp),intent(inout) :: a(0:)
    integer :: width,start,i
    real(dp) :: x,y
    width=1
    do while(width<size(a))
      do start=0,size(a)-1,2*width
        do i=start,start+width-1
          x=a(i);y=a(i+width);a(i)=x+y;a(i+width)=x-y
        end do
      end do
      width=2*width
    end do
  end subroutine fwht

  subroutine qra_decode(observed,cfg,payload,ok,iterations,max_iterations,decoded_word)
    real(dp),intent(in) :: observed(0:,:)
    type(qra_config),intent(in) :: cfg
    integer,intent(out) :: payload(77),iterations
    logical,intent(out) :: ok
    integer,optional,intent(in) :: max_iterations
    integer,optional,intent(out) :: decoded_word(65)
    real(dp),allocatable :: prior(:,:),v2c(:,:),c2v(:,:),transformed(:,:),product(:),posterior(:)
    real(dp) :: confidence
    integer :: q,limit,word(65),message(15),i,j,k,e,other,v,c,s,degree
    q=cfg%q;limit=100;if(present(max_iterations))limit=max_iterations
    if(size(observed,1)/=q.or.size(observed,2)/=cfg%ntransmitted)error stop 'Wrong intrinsic matrix size'
    if(any(observed<0.0_dp))error stop 'Negative intrinsic probability'
    allocate(prior(0:q-1,nv),v2c(0:q-1,ne),c2v(0:q-1,ne),transformed(0:q-1,3))
    allocate(product(0:q-1),posterior(0:q-1))
    prior=1.0_dp/real(q,dp)
    do i=1,cfg%ntransmitted
      v=cfg%transmitted(i)
      if(sum(observed(:,i))<=0.0_dp)error stop 'Zero intrinsic sum'
      prior(:,v)=observed(:,i)/sum(observed(:,i))
    end do
    if(cfg%bits==6)then
      prior(1:q-1:2,13)=0.0_dp ! Public 78th source bit is zero.
    else
      do s=0,q-1
        if(iand(s,7)/=0)prior(s,10)=0.0_dp
      end do
      prior(:,11:13)=0.0_dp;prior(0,11:13)=1.0_dp
    end if
    do v=1,nv
      prior(:,v)=prior(:,v)/sum(prior(:,v))
    end do
    do e=1,ne
      v2c(:,e)=prior(:,cfg%edge_variable(e))
    end do
    c2v=1.0_dp/real(q,dp);payload=0;ok=.false.;word=0
    do iterations=1,limit
      do c=1,nc
        degree=cfg%check_degree(c)
        do j=1,degree
          e=cfg%check_edge(j,c)
          do s=0,q-1
            transformed(cfg%permutation(s,e),j)=v2c(s,e)
          end do
          call fwht(transformed(:,j))
        end do
        do j=1,degree
          product=1.0_dp
          do k=1,degree
            if(k/=j)product=product*transformed(:,k)
          end do
          call fwht(product)
          product=max(product/real(q,dp),1.0e-15_dp)
          product=product/sum(product);e=cfg%check_edge(j,c)
          do s=0,q-1
            c2v(s,e)=product(cfg%permutation(s,e))
          end do
        end do
      end do
      confidence=0.0_dp
      do v=1,nv
        degree=cfg%variable_degree(v)
        product=1.0_dp
        do j=1,degree
          product=product*c2v(:,cfg%variable_edge(j,v))
        end do
        confidence=confidence+maxval(product)/max(sum(product),tiny(1.0_dp))
        posterior=prior(:,v)
        do j=1,degree
          posterior=posterior*c2v(:,cfg%variable_edge(j,v))
        end do
        word(v)=maxloc(posterior,dim=1)-1
        do j=1,degree
          e=cfg%variable_edge(j,v);product=prior(:,v)
          do k=1,degree
            if(k==j)cycle
            other=cfg%variable_edge(k,v);product=product*c2v(:,other)
          end do
          v2c(:,e)=product/max(sum(product),tiny(1.0_dp))
        end do
      end do
      ! Require concentrated extrinsic probabilities before checking syndrome/CRC.
      ! A uniform all-zero tie otherwise satisfies the algebraic checks.
      if(confidence<real(nv,dp)-0.01_dp)cycle
      if(qra_syndrome(word,cfg)/=0)cycle
      message=word(:15);call add_crc(cfg,message)
      if(any(message(14:15)/=word(14:15)))cycle
      ok=.true.
      do k=1,77
        i=(k-1)/cfg%bits+1;j=cfg%bits-1-modulo(k-1,cfg%bits)
        payload(k)=ibits(word(i),j,1)
      end do
      exit
    end do
    iterations=min(iterations,limit)
    if(present(decoded_word))decoded_word=word
  end subroutine qra_decode

  subroutine qra_metric(energy,noise,probability)
    ! Fixed Q65-style Es/N0 metric.
    ! log(I0) rational approximation is from qracodes.c (Nico Palermo).
    real(dp),intent(in) :: energy(0:,:),noise
    real(dp),intent(out) :: probability(0:,:)
    real(dp),parameter :: esno_metric=6.0_dp*(13.0_dp/63.0_dp)*10.0_dp**0.28_dp
    real(dp) :: argument(size(energy,1)),logp(size(energy,1)),squared(size(energy,1))
    integer :: i
    if(noise<=0.0_dp)error stop 'Noise estimate must be positive'
    do i=1,size(energy,2)
      argument=2.0_dp*sqrt(esno_metric*max(energy(:,i),0.0_dp)/noise)
      squared=argument**2
      logp=squared*(argument+0.039_dp)/(squared*0.9931_dp+argument*2.6936_dp+0.5185_dp)
      probability(:,i)=exp(max(logp-maxval(logp),-700.0_dp))
      probability(:,i)=probability(:,i)/sum(probability(:,i))
    end do
  end subroutine qra_metric
end module qra_soft_mod
