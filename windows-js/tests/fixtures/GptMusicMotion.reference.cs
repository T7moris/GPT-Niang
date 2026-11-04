using System;
public sealed class GptMusicMotion {
    public double X,Y,Vx,Vy,Floor,Width,FigureWidth,Dpi,Time,Bend,BendSpeed,Rock,RockSpeed,Lamp,LampSpeed,Pulse,Energy,Cycle;
    public int Impacts,Phase;public double Props;public int Direction=-1;
    double landed,lockStartPose,lastPointerX,lastPointerY,flightCeiling,pointerIdle;bool wasLocked,hasPointer,throwMomentum;
    public double ThrowX,ThrowY,FigureHeight;
    public double ReleaseIdleMs {get;private set;}
    public bool Held {get;private set;}
    public void BeginHold(){Held=true;wasLocked=false;Energy=0;BendSpeed=4;Vy=0;Props=0;ThrowX=ThrowY=0;pointerIdle=ReleaseIdleMs=0;hasPointer=false;throwMomentum=false;}
    public void BeginHold(double pointerX,double pointerY){BeginHold();lastPointerX=pointerX;lastPointerY=pointerY;hasPointer=true;}
    public void SamplePointer(double pointerX,double pointerY,double dt){
        if(dt<=0)return;
        if(hasPointer){
            double dx=pointerX-lastPointerX,dy=pointerY-lastPointerY;
            if(Math.Abs(dx)+Math.Abs(dy)>.1*Dpi){
                pointerIdle=0;
                double vx=dx/dt,vy=dy/dt,length=Math.Sqrt(vx*vx+vy*vy);
                double limit=Math.Min(1,2000*Dpi/Math.Max(1,length)),blend=1-Math.Exp(-dt/.025);
                ThrowX+=(vx*limit-ThrowX)*blend;ThrowY+=(vy*limit-ThrowY)*blend;
            }else{
                // A short gap before MouseUp is still part of the flick. Do not
                // average those zero-motion render samples into the release.
                double oldIdle=pointerIdle;pointerIdle+=dt;
                double decay=Math.Exp(-(Math.Max(0,pointerIdle-.080)-Math.Max(0,oldIdle-.080))/.025);
                ThrowX*=decay;ThrowY*=decay;
            }
        }
        lastPointerX=pointerX;lastPointerY=pointerY;hasPointer=true;
    }
    public void MoveHeld(double x,double y,double dt){
        MoveHeld(x,y,dt,x,y);
    }
    public void MoveHeld(double x,double y,double dt,double pointerX,double pointerY){
        SamplePointer(pointerX,pointerY,dt);
        double margin=FlightMargin;X=Clamp(x,margin,Math.Max(margin,Width-margin));
        double target=Clamp(y,16*Dpi,Floor);Spring(ref Y,ref Vy,target,dt,22,.72);
        if(Y>Floor){Y=Floor;Vy=Math.Min(0,Vy);}
    }
    public void Release(){
        if(!Held)return;Held=false;Phase=0;Impacts=0;Props=0;Vx=ThrowX;Vy=ThrowY;ReleaseIdleMs=pointerIdle*1000;
        throwMomentum=Math.Abs(Vx)>120*Dpi;
        flightCeiling=Math.Min(Y,Math.Min(Floor,FigureHeight*1.22+16*Dpi));
        if(Math.Abs(Vx)+Math.Abs(Vy)<60*Dpi)Vy=-90*Dpi;
        if(Math.Abs(Vx)>5*Dpi)Direction=Vx>0?1:-1;
    }
    public GptMusicMotion(double x,double y,double width,double floor,double figure,double dpi){X=x;Y=y;Width=width;Floor=floor;FigureWidth=FigureHeight=figure;Dpi=dpi;}
    public void Resize(double width,double floor,double figure,double dpi){
        if(FigureWidth>0)FigureHeight*=figure/FigureWidth;
        if(Width>0)X=X/Width*width;Y+=floor-Floor;Width=width;Floor=floor;FigureWidth=figure;Dpi=dpi;
        if(Phase>0&&!Held)Y=Floor;double m=Margin;X=Clamp(X,m,Math.Max(m,Width-m));
    }
    public double Margin {get{return Math.Min(Width/2,24*Dpi+FigureWidth*.86);}}
    public double FlightMargin {get{return Math.Min(Width/2,4*Dpi+FigureWidth*.52);}}
    void MoveAir(double dt,double drag){
        X+=Vx*dt;Vx*=Math.Exp(-dt*drag);double m=FlightMargin;
        if(X<m){X=m;if(Vx<0)Vx=-Vx*.62;Direction=1;}
        if(X>Width-m){X=Width-m;if(Vx>0)Vx=-Vx*.62;Direction=-1;}
    }
    public static double Clamp(double x,double low,double high){return Math.Max(low,Math.Min(high,x));}
    public static void Spring(ref double value,ref double speed,double target,double dt,double frequency,double damping){
        for(double remaining=dt;remaining>0;){double s=Math.Min(remaining,1.0/240);speed+=((target-value)*frequency*frequency-2*damping*frequency*speed)*s;value+=speed*s;remaining-=s;}
    }
    // One continuous cycle per confirmed musical beat. The lowest pose is ON
    // the beat; anticipation comes before it, rather than reacting afterwards.
    public static double BeatPose(double phase){
        phase-=Math.Floor(phase);
        if(phase<.32)return .12+.28*Math.Cos(Math.PI*phase/.32);
        if(phase<.66)return -.08*(1+Math.Cos(Math.PI*(phase-.32)/.34));
        if(phase<.78)return 0;
        return .20*(1-Math.Cos(Math.PI*(phase-.78)/.22));
    }
    public void Step(double dt,bool paused,bool locked,double phase,double period,double strength){
        Step(dt,paused,locked,phase,period,strength,dt);
    }
    public void Step(double dt,bool paused,bool locked,double phase,double period,double strength,double clockElapsed){
        dt=Clamp(dt,0,.12);if(dt<=0)return;
        clockElapsed=Math.Max(0,clockElapsed);
        if(paused){
            Spring(ref Bend,ref BendSpeed,0,dt,20,.8);Spring(ref Rock,ref RockSpeed,0,dt,14,.8);Spring(ref Lamp,ref LampSpeed,0,dt,7,.8);
            if(Phase>=2)Vx*=Math.Exp(-dt*12);Pulse*=Math.Exp(-dt*10);Energy=0;wasLocked=false;return;
        }
        Time+=dt;
        if(Held){Spring(ref Bend,ref BendSpeed,-.045,dt,20,.42);Pulse=0;return;}
        if(Phase==0){
            for(double remaining=dt;remaining>0&&Phase==0;){
                double step=Math.Min(remaining,1.0/240);MoveAir(step,.30);Vy+=1180*Dpi*step;Y+=Vy*step;
                double ceiling=Math.Min(Floor,FigureHeight*1.22+16*Dpi);
                if(flightCeiling>0)ceiling=Math.Min(ceiling,flightCeiling);
                if(Y<ceiling&&Vy<0){Y=ceiling;Vy=-Vy*.42;}
                if(Y>=Floor&&Vy>0){Y=Floor;Impacts++;Bend=Math.Min(.30,Vy/(2500*Dpi));BendSpeed=0;
                    Vx*=throwMomentum?.94:.68;if(Impacts<=2)Vy=-Vy*.52;else{Vy=0;Phase=1;landed=Time;}}
                remaining-=step;
            }
            Spring(ref Bend,ref BendSpeed,0,dt,20,.67);return;
        }
        Y=Floor;Vy=0;
        if(Phase==1){Props=Math.Min(1,(Time-landed)/.25);MoveAir(dt,throwMomentum?.75:10);Spring(ref Bend,ref BendSpeed,0,dt,20,.67);if(Props>=1)Phase=2;return;}
        double oldBend=Bend;
        locked=locked&&period>=.28&&period<=1.0;
        if(locked){
            if(!wasLocked){Cycle=phase;lockStartPose=Bend;Energy=0;}
            else{double predicted=Cycle+clockElapsed/period,error=phase-predicted;error-=Math.Round(error);
                Cycle=predicted+Clamp(error,-.08,.08)*(1-Math.Exp(-dt/.12));}
            Energy+=(1-Energy)*(1-Math.Exp(-dt/.12));Bend=lockStartPose*(1-Energy)+BeatPose(Cycle)*Clamp(strength,.8,1)*Energy;
        }else{Energy*=Math.Exp(-dt/.12);Bend*=Math.Exp(-dt/.10);}
        wasLocked=locked;BendSpeed=(Bend-oldBend)/dt;Pulse=Clamp(Bend/.4,0,1);
        Spring(ref Rock,ref RockSpeed,locked?7.5*Math.Sin(2*Math.PI*(Cycle-.04))*Energy:0,dt,18,.7);
        Spring(ref Lamp,ref LampSpeed,locked?8*Math.Sin(Math.PI*Cycle)*Energy:0,dt,9,.75);
        // Ground contact absorbs the vertical bounce, not the user's sideways
        // throw. Let that momentum glide out while the musical pose continues.
        if(throwMomentum&&Math.Abs(Vx)>35*Dpi){MoveAir(dt,.75);return;}
        throwMomentum=false;
        double margin=Margin;
        if(X<margin)Direction=1;if(X>Width-margin)Direction=-1;
        double available=Direction<0?X-margin:Width-margin-X;
        double rate=locked?4:10;
        double wanted=Direction*25*Dpi*Energy*Math.Min(1,Math.Max(0,available)/(28*Dpi)),decay=Math.Exp(-dt*rate),old=Vx;
        Vx=wanted+(old-wanted)*decay;X+=wanted*dt+(old-wanted)*(1-decay)/rate;
        if(X<margin+1*Dpi&&Direction<0)Direction=1;if(X>Width-margin-1*Dpi&&Direction>0)Direction=-1;
        X=Clamp(X,FlightMargin,Math.Max(FlightMargin,Width-FlightMargin));
        if(Math.Abs(Bend)<.00001&&Math.Abs(BendSpeed)<.0001)Bend=BendSpeed=0;
        if(Energy<.00001)Energy=0;if(Pulse<.00001)Pulse=0;
    }
    public void RespondToOnset(double age,double strength){
        if(Held||Phase<2||age<0||age>.34)return;
        // No invented clock while acquiring: this one elastic response belongs
        // to the observed bass onset only. The confirmed grid takes over later.
        Bend=BeatPose(age/.5)*Clamp(strength,.8,1);BendSpeed=0;Pulse=Clamp(Bend/.4,0,1);
        Energy=Math.Max(Energy,Math.Exp(-age/.12));
    }
    public bool Moving {get{return Phase<2||Energy>.001||Math.Abs(Bend)>.0001||Math.Abs(Rock)>.005||Math.Abs(RockSpeed)>.01||Math.Abs(Lamp)>.005||Math.Abs(LampSpeed)>.01||Math.Abs(Vx)>.05;}}
}
