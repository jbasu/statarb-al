## Trading simulation function
## input: signals object, prices df




## the signals object here is assumed to be a list of dates
## positions matrix is a matrix of instruments / pairs
## rows ("P") indicate instruments for which signals are generated
## cols ("Q") indicate intruments acting as pairs (beta factors)
## NB: q should always also include the underlying p
run.trading.simulation <- function(  signals.struct, prices
                                   , instr.p, instr.q, pq.classifier
                                   , debug=FALSE, warn=FALSE, stop.on.wrn=FALSE
                                   , silent=FALSE, outfile="", debug.name=instr.p[1]
                                   , dbg.transactions=FALSE
                                   , init.cash=100000
                                   , pos.allocation="beta.neutral"){
  ## equity.blown.thr <- 10000
  if(outfile!="")
    if(file.exists(outfile)) { file.remove(outfile) }
  stopifnot(!is.unsorted(rev(names(signals.struct$sig.dates)))) ##o/w next line is wrong
  signals <- rev(signals.struct$sig.dates)
  dates <- names(signals)
  stopifnot(all(instr.p %in% signals.struct$tickers))
  stopifnot(all(dates %in% row.names(prices))) ##prices dates range
                                        # must include all signals+more
  stopifnot(all(instr.p %in% instr.q))
  stopifnot(all(instr.q %in% names(prices)))
  prices <- prices[dates,] ## align the data frames
  stopifnot(all(row.names(prices)==dates))
  positions <-as.data.frame(matrix(0,length(instr.p),length(instr.q)))
  names(positions) <- instr.q;  row.names(positions) <- instr.p

  ## output: number of shares: e.g. (100,-100) for beta=1, tot=S=b=1
  long.shr.amounts <- function(beta,tot,S,b){ #S is price of stock, b is price of pair
    if(pos.allocation=="beta.neutral"){       #tot is the amount inv. in  stk (leverage factor * equity/num. stocks)
      c(s.shares=round(tot/S), b.shares=-round(beta*tot/b))
    }else{ #"dollar neutral": long $tot S, short $tot b
      c(s.shares=round(tot/S),b.shares=-round(tot/b))
    } }

  
  prealloc.signal.mtx <- function(stocks,dates){
    x <- array(0.0,c(length(stocks),length(dates)))
    colnames(x) <- dates; rownames(x) <- stocks
    return(x) }

  s.action <- prealloc.signal.mtx(instr.p,dates)
  k <- 0
  lambda <- 2/max(100,length(instr.p))
  nav <- 0; cash <- init.cash; equity <- rep(0.,length(dates))
  
  for(i in seq(along=dates)){
    if(!silent) { if(i %% 50 == 0) cat(i," ") }
    net.positions <- apply(positions,2,sum)
    prices.0na <- prices[i,names(net.positions)]; prices.0na[is.na(prices.0na)] <- 0
    nav <- sum(prices.0na*net.positions)
    equity[i] <- cash + nav
    for(j in seq(along=row.names(positions))){
      this.name <- row.names(positions)[j]
      pair.name <- pq.classifier[this.name,]$SEC_ETF
      if(!(this.name %in% instr.p)) next
      if(any(is.na(prices[i,c(this.name,pair.name)]))) next
      sig.idx <- which(signals.struct$tickers==this.name)
##    if(dates[i]=="20030328") { browser() }
      sig <- decode.signals(signals[[i]][sig.idx,])
      params <- decode.params(signals[[i]][sig.idx,])
      k <- match(this.name,instr.p)
      betas <- decode.betas(signals[[i]][sig.idx,])
      this.p <- positions[j,this.name]
      if(!sig["model.valid"] || is.na(sig["model.valid"])){ ## NA || TRUE -> TRUE, NA && TRUE -> NA, NA && FALSE -> FALSE
        if(debug && this.name==debug.name) cat(i,"pos:",this.p,"eq[i]:",equity[i],"beta ",betas," prices: ",price.s.b," num shares: ",num.shrs,"INVALID\n",file=outfile,append=TRUE)
      }else{
        tot <- lambda*equity[i] # investment amount
        price.s.b <- c(prices[i,this.name], prices[i,pair.name])
        num.shrs <- long.shr.amounts(betas,tot, price.s.b[1],
                                     price.s.b[2])
        if(debug && this.name==debug.name) cat(i,"pos:",this.p,"eq[i]:",equity[i],"beta ",betas," prices: ",price.s.b," num shares: ",num.shrs,"\n",file=outfile,append=TRUE)
        if(sig["sto"]){
          if(!(this.p<0)&& (-num.shrs["s.shares"])<0){ #flat or long (but shouldn't be long here)
            ##	sell stock, buy factors #opening short (if flat before, as we should
            ##be)
            ## num.shrs has the correct signs for long, this is short though
            num.shrs <- -num.shrs
            positions[j,this.name] <- positions[j,this.name] + num.shrs["s.shares"]
            positions[j,pair.name] <- positions[j,pair.name] + num.shrs["b.shares"]
            cash <- cash - sum(price.s.b * num.shrs)
            s.action[k,i] <- 1
            if((debug && this.name==debug.name)||dbg.transactions)
              cat(i,this.name,"STO: 'acquiring'",num.shrs,"paying ",sum(price.s.b * num.shrs),"cash=",cash,"\n")
            if(this.p>0 && warn) { cat(paste("\nSTO tripped while long, on day",i,"for stock",this.name),"\n"); if(stop.on.wrn) stop() }
          }
        } #else do nothing #already short 
        if(sig["close.short"]){
          if(this.p<0){
            ## buy stock, sell factors #closing short
            cash <- cash +
              sum(price.s.b*c(positions[j,this.name],positions[j,pair.name]))
            s.action[k,i] <- 1
            if((debug && this.name==debug.name)||dbg.transactions)
              cat(i,this.name,"CLOSING SHORT: paying ",-sum(price.s.b*c(positions[j,this.name],positions[j,pair.name])),"cash=",cash,"\n")
            positions[j,this.name] <- 0
            positions[j,pair.name] <- 0
            
          }
        }#else: do nothing
        if(sig["bto"]){
          if(!(this.p>0) && num.shrs["s.shares"]>0){ #flat or short (but shouldn't be short here)
            ##        buy stock, sell factors #opening long
            positions[j,this.name] <- positions[j,this.name] + num.shrs["s.shares"]
            positions[j,pair.name] <- positions[j,pair.name] + num.shrs["b.shares"]
            cash <- cash - sum(price.s.b * num.shrs)
            s.action[k,i] <- 1
            if(this.p<0 && warn){ cat(paste("\nBTO tripped while short, on day",i,"for stock",this.name,"\n")); if(stop.on.wrn) stop() }
            if((debug && this.name==debug.name)||dbg.transactions)
              cat(i,this.name,"BTO: 'acquiring'",num.shrs," paying ",sum(price.s.b * num.shrs),"cash=",cash,"\n")
          }# else: do nothing #already long
        }
        if(sig["close.long"]){
          if(this.p>0){
            ##          sell stock, buy factors #closing long
            cash <- cash +
              sum(price.s.b*c(positions[j,this.name],positions[j,pair.name]))
            s.action[k,i] <- 1
            if((debug && this.name==debug.name)||dbg.transactions)
              cat(i,this.name,"CLOSING LONG: paying ",-sum(price.s.b*c(positions[j,this.name],positions[j,pair.name])),"cash=",cash,"\n")
            positions[j,this.name] <- 0
            positions[j,pair.name] <- 0

          }# else: do nothing
        }
      }
    }
  }
  return(list(dates=dates,cash=cash,nav=nav,equity=equity,log=list(actions=s.action)))
}



