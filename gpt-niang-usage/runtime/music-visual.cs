using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

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

// No PowerShell callbacks run on these animation or capture frames. Native
// movement is delegated to the existing follower's single position writer.
public sealed class GptMusicVisual : IDisposable {
    readonly Window window;readonly Image girl;readonly FrameworkElement bubble;readonly Canvas root;
    readonly DispatcherTimer wake;
    DispatcherOperation pendingPosition;
    readonly Action<int,int> followOffset;readonly GptMusicCapture capture;
    readonly MusicArt under,over;readonly ScaleTransform press=new ScaleTransform();readonly Color[] palette;
    readonly Transform oldTransform;readonly Point oldOrigin;readonly bool glasses;
    readonly FrameworkElement menuButton;double menuLeft,menuTop;
    double baseLeft,baseTop,normalX,normalY,relativeX,bottomDistance,dpi=1,figurePhysical,anchorX,anchorY,lastFrame,colorTime,artTime,lastLightPaint,grabX,grabY,lastGrabAt;
    readonly Point initialFoot;
    bool follow,allowed,blocked,visible,topmost,disposed,wasPaused,appearanceReady;IntPtr host,widget;
    Rect imageRect,alpha;HwndSource lampSource;MusicLamp lampArt;int lampBand=-1;
    static readonly Color RoomColor=Color.FromArgb(145,10,7,23);
    public bool Enabled {get;private set;}
    public bool ColorEnabled {get;set;}
    public Action<IntPtr,int,int,int> FollowLamp {get;set;}
    public Func<int[]> HostFrame {get;set;}
    public bool Paused {get;private set;}
    public string Error {get;private set;}
    public GptMusicMotion Motion {get;private set;}
    public GptMusicAudioSnapshot Audio {get;private set;}
    public IntPtr LampHandle {get{return lampSource==null?IntPtr.Zero:lampSource.Handle;}}
    public void BeginHold(double cursorX,double cursorY){
        if(Motion==null)return;var f=FrameBounds();grabX=Motion.X-(cursorX-f.Left);grabY=Motion.Y-(cursorY-f.Top)-Math.Min(52*dpi,figurePhysical*.45);Motion.BeginHold(cursorX,cursorY);lastGrabAt=GptMusicCapture.NowMs;Redraw();
    }
    public void EndHold(){
        if(Motion==null||!Motion.Held)return;
        // MouseUp hands the already sampled vector straight to the physics.
        Motion.Release();Frame(this,EventArgs.Empty);Redraw();
    }
    void TrackPointer(Rect frame,double now) {
        MusicNative.Point cursor;if(!MusicNative.GetCursorPos(out cursor))return;
        double dt=GptMusicMotion.Clamp((now-lastGrabAt)/1000,0,.12);lastGrabAt=now;
        Motion.MoveHeld(cursor.X-frame.Left+grabX,cursor.Y-frame.Top+grabY,dt,cursor.X,cursor.Y);
    }
    void Drag(object sender,System.Windows.Input.MouseEventArgs e) {
        if(!Enabled||disposed||Motion==null||!Motion.Held||!girl.IsMouseCaptured)return;
        try {
            if(!visible||!allowed||!window.IsVisible||InteractionBlocked())return;
            var frame=FrameBounds();if(frame.Width<=0||frame.Height<=0)return;
            Paused=false;TrackPointer(frame,GptMusicCapture.NowMs);ApplyPosition();e.Handled=true;
        } catch(Exception ex) {Error=ex.ToString();Stop(false);}
    }
    public void Redraw(){under.InvalidateVisual();over.InvalidateVisual();}
    public void SetVisibility(bool visible,bool blocked){this.visible=visible;this.blocked=blocked;if(!visible||blocked){Paused=true;if(!visible&&lampSource!=null)MusicNative.ShowWindow(lampSource.Handle,0);Redraw();}}
    public GptMusicVisual(Window window,Image girl,FrameworkElement bubble,Action<int,int> followOffset,Color[] colors,bool useGlasses) {
        this.window=window;this.girl=girl;this.bubble=bubble;this.followOffset=followOffset;palette=colors;glasses=useGlasses;
        root=(Canvas)girl.Parent;oldTransform=girl.RenderTransform;oldOrigin=girl.RenderTransformOrigin;
        baseLeft=Canvas.GetLeft(girl);baseTop=Canvas.GetTop(girl);
        menuButton=window.FindName("MenuButton") as FrameworkElement;if(menuButton!=null){menuLeft=Canvas.GetLeft(menuButton);menuTop=Canvas.GetTop(menuButton);}
        var first=AlphaBounds((BitmapSource)girl.Source,girl.Width,girl.Height);initialFoot=girl.PointToScreen(new Point(first.Left+first.Width/2,first.Bottom));
        under=new MusicArt(this,false);over=new MusicArt(this,true);
        root.Children.Insert(root.Children.IndexOf(girl),under);root.Children.Insert(root.Children.IndexOf(girl)+1,over);
        capture=new GptMusicCapture(true);Enabled=true;ColorEnabled=false;
        RefreshLayout();lastFrame=GptMusicCapture.NowMs;
        girl.PreviewMouseMove+=Drag;CompositionTarget.Rendering+=Frame;
        // Transparent/occluded WPF windows may stop requesting render frames.
        // Wake only when that happens; normal motion still follows Rendering.
        wake=new DispatcherTimer(DispatcherPriority.Background,window.Dispatcher);
        wake.Interval=TimeSpan.FromMilliseconds(16);wake.Tick+=Wake;wake.Start();
    }
    void Wake(object sender,EventArgs e){if(Enabled&&!disposed&&visible&&window.IsVisible&&GptMusicCapture.NowMs-lastFrame>=32)Frame(sender,e);}
    public void RefreshLayout() {
        var source=(BitmapSource)girl.Source;alpha=AlphaBounds(source,girl.Width,girl.Height);
        double left=175-(alpha.Left+alpha.Width/2),top=350-alpha.Bottom;
        Canvas.SetLeft(girl,left);Canvas.SetTop(girl,top);girl.RenderTransformOrigin=new Point(0,0);
        if(menuButton!=null){Canvas.SetLeft(menuButton,menuLeft+left-baseLeft);Canvas.SetTop(menuButton,menuTop+top-baseTop);}
        press.CenterX=alpha.Left+alpha.Width/2;press.CenterY=alpha.Bottom;girl.RenderTransform=press;
        imageRect=new Rect(left,top,girl.Width,girl.Height);
        window.UpdateLayout();MeasureAnchor();under.InvalidateVisual();over.InvalidateVisual();
    }
    // Called immediately after the ordinary layout recalculates size or DPI.
    public void CaptureBaseLayout() {baseLeft=Canvas.GetLeft(girl);baseTop=Canvas.GetTop(girl);if(menuButton!=null){menuLeft=Canvas.GetLeft(menuButton);menuTop=Canvas.GetTop(menuButton);}RefreshLayout();}
    void MeasureAnchor() {
        var p=girl.PointToScreen(new Point(alpha.Left+alpha.Width/2,alpha.Bottom));MusicNative.Rect rect;
        if(MusicNative.GetWindowRect(widget,out rect)){anchorX=p.X-rect.Left;anchorY=p.Y-rect.Top;}
        var l=girl.PointToScreen(new Point(alpha.Left,alpha.Bottom));var r=girl.PointToScreen(new Point(alpha.Right,alpha.Bottom));figurePhysical=Math.Abs(r.X-l.X);
    }
    public void Configure(IntPtr widget,IntPtr host,bool follow,bool visible,bool blocked,bool topmost,
                          double normalX,double normalY,double frameLeft,double frameBottom,double dpi) {
        this.widget=widget;this.host=host;this.follow=follow;this.visible=visible;this.blocked=blocked;this.topmost=topmost;
        this.normalX=normalX;this.normalY=normalY;relativeX=normalX-frameLeft;bottomDistance=frameBottom-normalY;this.dpi=dpi;
        MeasureAnchor();var frame=FrameBounds();allowed=frame.Width>=64*dpi&&frame.Height>=64*dpi;
        if(Motion==null&&allowed){
            Motion=new GptMusicMotion(initialFoot.X-frame.Left,initialFoot.Y-frame.Top,frame.Width,frame.Height,figurePhysical,dpi);
            Motion.FigureHeight=figurePhysical*alpha.Height/alpha.Width;
            int px=(int)Math.Round(initialFoot.X-anchorX),py=(int)Math.Round(initialFoot.Y-anchorY);
            if(follow)followOffset((int)Math.Round(px-(frame.Left+relativeX)),(int)Math.Round(py-(frame.Bottom-bottomDistance)));
            else MusicNative.SetWindowPos(widget,IntPtr.Zero,px,py,0,0,0x615);
        }else if(Motion!=null&&allowed&&(Math.Abs(Motion.Width-frame.Width)>.5||Math.Abs(Motion.Floor-frame.Height)>.5||Math.Abs(Motion.FigureWidth-figurePhysical)>.5))
            Motion.Resize(frame.Width,frame.Height,figurePhysical,dpi);
        PositionLamp(frame,visible&&allowed&&window.IsVisible,true);
    }
    Rect FrameBounds() {
        if(follow){
            var bounds=HostFrame==null?null:HostFrame();
            if(bounds!=null)return new Rect(bounds[0],bounds[1],Math.Max(0,bounds[2]-bounds[0]),Math.Max(0,bounds[3]-bounds[1]));
            MusicNative.Rect r=MusicNative.Frame(host);return new Rect(r.Left,r.Top,Math.Max(0,r.Right-r.Left),Math.Max(0,r.Bottom-r.Top));
        }
        MusicNative.Rect wr;MusicNative.GetWindowRect(widget,out wr);
        var screen=System.Windows.Forms.Screen.FromPoint(new System.Drawing.Point(wr.Left+Math.Max(1,wr.Right-wr.Left)/2,wr.Top+Math.Max(1,wr.Bottom-wr.Top)/2));
        var a=screen.WorkingArea;return new Rect(a.Left,a.Top,a.Width,a.Height);
    }
    bool InteractionBlocked() {
        bool held=Motion!=null&&Motion.Held;
        bool flying=Motion!=null&&!held&&Motion.Phase<2;
        return blocked||(window.ContextMenu!=null&&window.ContextMenu.IsOpen)||(!held&&!flying&&(girl.IsMouseCaptured||(bubble!=null&&bubble.Visibility==Visibility.Visible)));
    }
    void ApplyPosition() {
        if(disposed||!Enabled||Paused||Motion==null||!visible||!allowed||!window.IsVisible||InteractionBlocked())return;
        // Resolve the latest host frame and motion at delivery, so a host move,
        // resize or drag cannot leave a queued absolute position behind.
        var frame=FrameBounds();if(frame.Width<=0||frame.Height<=0)return;
        int px=(int)Math.Round(frame.Left+Motion.X-anchorX),py=(int)Math.Round(frame.Top+Motion.Y-anchorY);
        if(follow)followOffset((int)Math.Round(px-(frame.Left+relativeX)),(int)Math.Round(py-(frame.Bottom-bottomDistance)));
        else {
            // Skip the synchronous pre-move render barrier for this position-only move.
            MusicNative.Rect current;
            if(!MusicNative.GetWindowRect(widget,out current)||current.Left!=px||current.Top!=py)MusicNative.SetWindowPos(widget,IntPtr.Zero,px,py,0,0,0x615);
        }
    }
    void CancelPendingPosition() {
        if(pendingPosition!=null){if(pendingPosition.Status==DispatcherOperationStatus.Pending)pendingPosition.Abort();pendingPosition=null;}
    }
    void RequestPosition() {
        // All paths, including release and timer wake-ups, leave native delivery until after drawing.
        if(pendingPosition!=null&&pendingPosition.Status==DispatcherOperationStatus.Pending)return;
        // Moving a layered HWND from its own Rendering callback can stall
        // composition. Deliver one latest position after that render completes.
        pendingPosition=window.Dispatcher.BeginInvoke(DispatcherPriority.Background,new Action(delegate{pendingPosition=null;ApplyPosition();}));
    }
    void Frame(object sender,EventArgs e) {
        if(!Enabled||disposed)return;
        try {
            double now=GptMusicCapture.NowMs,elapsed=Math.Max(0,(now-lastFrame)/1000),dt=Math.Min(.12,elapsed);lastFrame=now;Audio=capture.Snapshot();
            bool held=Motion!=null&&Motion.Held;
            bool interaction=InteractionBlocked();
            Paused=!visible||!allowed||interaction||!window.IsVisible;
            bool locked=Audio.RhythmLocked&&Audio.PeriodMs>0;
            double phase=locked?1+(now-Audio.NextBeatAtMs)/Audio.PeriodMs:0;
            if(Motion==null)return;
            var frame=FrameBounds();if(frame.Width<=0||frame.Height<=0)return;
            if(Math.Abs(Motion.Width-frame.Width)>.5||Math.Abs(Motion.Floor-frame.Height)>.5)Motion.Resize(frame.Width,frame.Height,figurePhysical,dpi);
            if(held&&!Paused&&girl.IsMouseCaptured)TrackPointer(frame,now);
            bool changed=Motion.Moving||locked||wasPaused!=Paused;
            Motion.Step(dt,Paused,locked,phase,Audio.PeriodMs/1000,1,elapsed);
            if(!Paused&&!locked&&Audio.SourceProcessId!=0&&Audio.Sequence>0)Motion.RespondToOnset((now-Audio.BeatAtMs)/1000,Audio.Strength);
            press.ScaleX=1;press.ScaleY=1-Motion.Bend;
            if(Motion.Props>=1)appearanceReady=true;
            if(!Paused) {
                if(Motion.Energy>.005||Motion.Pulse>.005){double flow=.3+.7*Motion.Energy;artTime+=dt*flow;if(ColorEnabled)colorTime+=dt*flow;changed=true;}
                RequestPosition();
            }
            if(changed){under.InvalidateVisual();over.InvalidateVisual();}
            PositionLamp(frame,visible&&allowed&&window.IsVisible,changed);wasPaused=Paused;
        } catch(Exception ex) {Error=ex.ToString();Stop(false);}
    }
    void PositionLamp(Rect frame,bool show,bool redraw) {
        if(!show){if(lampSource!=null&&MusicNative.IsWindowVisible(lampSource.Handle))MusicNative.ShowWindow(lampSource.Handle,0);return;}
        double d=Math.Max(32,Math.Min(72,figurePhysical*.42))/dpi,w=frame.Width/dpi,h=frame.Height/dpi;
        if(lampSource==null) {
            var p=new HwndSourceParameters("GPT Niang music mirror ball");p.WindowStyle=unchecked((int)0x80000000);p.ExtendedWindowStyle=0x080000A0;
            p.Width=(int)Math.Ceiling(w*dpi);p.Height=(int)Math.Ceiling(h*dpi);p.UsesPerPixelOpacity=true;
            lampSource=new HwndSource(p);lampArt=new MusicLamp(this){Width=w,Height=h};lampSource.RootVisual=lampArt;
            lampSource.CompositionTarget.BackgroundColor=RoomColor;lampSource.AddHook(LampHook);redraw=true;
        }
        if(Math.Abs(lampArt.Diameter-d)>.01)redraw=true;
        lampArt.Width=w;lampArt.Height=h;lampArt.Diameter=d;lampArt.Top=follow?52:4;
        if(redraw&&GptMusicCapture.NowMs-lastLightPaint>=1000.0/30){lampArt.InvalidateVisual();lastLightPaint=GptMusicCapture.NowMs;}
        int band=(MusicNative.GetWindowLongPtr(follow?host:widget,-20).ToInt64()&8)!=0?1:0;
        if(lampBand!=band){MusicNative.SetWindowPos(lampSource.Handle,band==1?new IntPtr(-1):new IntPtr(-2),0,0,0,0,0x213);lampBand=band;}
        int x=(int)Math.Round(frame.Left),y=(int)Math.Round(frame.Top),pw=(int)Math.Round(frame.Width),ph=(int)Math.Round(frame.Height);MusicNative.Rect current;
        if(FollowLamp!=null)FollowLamp(follow?lampSource.Handle:IntPtr.Zero,pw,ph,0);
        IntPtr above=follow?MusicNative.PreviousVisible(host):widget;
        if(MusicNative.IsWindowVisible(lampSource.Handle)&&MusicNative.GetWindowRect(lampSource.Handle,out current)&&current.Left==x&&current.Top==y&&current.Right-current.Left==pw&&current.Bottom-current.Top==ph&&(follow?above==lampSource.Handle:MusicNative.GetWindow(widget,2)==lampSource.Handle))return;
        // Below the character, above Codex, and below every app covering Codex.
        if(follow&&above==lampSource.Handle)above=MusicNative.PreviousVisible(above);
        if(above==IntPtr.Zero||(band==0&&(MusicNative.GetWindowLongPtr(above,-20).ToInt64()&8)!=0))above=IntPtr.Zero;
        MusicNative.SetWindowPos(lampSource.Handle,above,x,y,pw,ph,0x250);
    }
    IntPtr LampHook(IntPtr h,int msg,IntPtr w,IntPtr l,ref bool handled) {
        if(msg==0x84){handled=true;return new IntPtr(-1);}if(msg==0x21){handled=true;return new IntPtr(3);}return IntPtr.Zero;
    }
    public void Stop(bool keepPosition) {
        if(disposed)return;disposed=true;Enabled=false;girl.PreviewMouseMove-=Drag;CompositionTarget.Rendering-=Frame;CancelPendingPosition();wake.Stop();wake.Tick-=Wake;capture.Dispose();
        // A window that is already closing can reject PointToScreen. Layout and
        // native resources must still be released in that case.
        Point foot=new Point();bool haveFoot=false;
        try{foot=girl.PointToScreen(new Point(alpha.Left+alpha.Width/2,alpha.Bottom));haveFoot=true;}catch{}
        if(FollowLamp!=null)FollowLamp(IntPtr.Zero,0,0,0);
        if(lampSource!=null){lampSource.Dispose();lampSource=null;}
        root.Children.Remove(under);root.Children.Remove(over);girl.RenderTransform=oldTransform;girl.RenderTransformOrigin=oldOrigin;
        Canvas.SetLeft(girl,baseLeft);Canvas.SetTop(girl,baseTop);window.UpdateLayout();
        if(menuButton!=null){Canvas.SetLeft(menuButton,menuLeft);Canvas.SetTop(menuButton,menuTop);}
        followOffset(0,0);
        if(keepPosition&&haveFoot) {
            try{
                var after=girl.PointToScreen(new Point(alpha.Left+alpha.Width/2,alpha.Bottom));MusicNative.Rect r;
                if(MusicNative.GetWindowRect(widget,out r))MusicNative.SetWindowPos(widget,IntPtr.Zero,(int)Math.Round(r.Left+foot.X-after.X),(int)Math.Round(r.Top+foot.Y-after.Y),0,0,0x215);
            }catch{}
        } else if(!follow)MusicNative.SetWindowPos(widget,IntPtr.Zero,(int)Math.Round(normalX),(int)Math.Round(normalY),0,0,0x215);
    }
    public void Dispose(){Stop(false);}
    public static Rect AlphaBounds(BitmapSource image,double width,double height) {
        var rgba=new FormatConvertedBitmap(image,PixelFormats.Bgra32,null,0);byte[] pixels=new byte[rgba.PixelWidth*rgba.PixelHeight*4];rgba.CopyPixels(pixels,rgba.PixelWidth*4,0);
        int l=rgba.PixelWidth,t=rgba.PixelHeight,r=-1,b=-1;
        for(int y=0;y<rgba.PixelHeight;y++)for(int x=0;x<rgba.PixelWidth;x++)if(pixels[(y*rgba.PixelWidth+x)*4+3]>12){l=Math.Min(l,x);t=Math.Min(t,y);r=Math.Max(r,x);b=Math.Max(b,y);}
        if(r<l||b<t)throw new ArgumentException("The character has no visible pixels.");
        double s=Math.Min(width/image.PixelWidth,height/image.PixelHeight);
        return new Rect((width-image.PixelWidth*s)/2+l*s,(height-image.PixelHeight*s)/2+t*s,(r-l+1)*s,(b-t+1)*s);
    }
    sealed class MusicArt : FrameworkElement {
        readonly GptMusicVisual owner;readonly bool overlay;
        public MusicArt(GptMusicVisual owner,bool overlay){this.owner=owner;this.overlay=overlay;Width=Height=350;IsHitTestVisible=false;}
        protected override void OnRender(DrawingContext dc) {if(owner.Motion==null||!owner.Enabled||!owner.visible)return;if(overlay)owner.DrawOver(dc);else owner.DrawUnder(dc);}
    }
    static SolidColorBrush Brush(string hex){var b=new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));b.Freeze();return b;}
    static readonly Brush Shell=Brush("#272038"),Side=Brush("#16131f"),Trim=Brush("#aa8ad9"),Led=Brush("#91e0e1"),Cone=Brush("#403252"),Core=Brush("#b89bd2");
    static readonly Pen TrimPen=new Pen(Trim,2),LedPen=new Pen(Led,1.7),Arm=new Pen(Brush("#36313f"),2),LensRim=new Pen(Brush("#302c3e"),1.9);
    static readonly Geometry LeftLens=Geometry.Parse("M -59,-12 Q -35,-17 -10,-12 L -11,5 Q -13,21 -34,21 Q -55,21 -57,7 Z"),RightLens=Geometry.Parse("M 10,-12 Q 34,-16 57,-12 L 55,6 Q 53,21 33,21 Q 13,21 12,5 Z");
    static readonly Geometry Arms=Geometry.Parse("M -56,-8 Q -66,-11 -73,-8 M 53,-8 Q 62,-14 69,-19 M -11,-6 Q 0,-12 12,-6");
    static readonly LinearGradientBrush Lens=new LinearGradientBrush((Color)ColorConverter.ConvertFromString("#171527"),(Color)ColorConverter.ConvertFromString("#343044"),90);
    void DrawUnder(DrawingContext dc) {
        double f=alpha.Width,p=Motion.Props;if(p<=0)return;
        dc.PushOpacity(p);var shadow=new SolidColorBrush(Color.FromArgb((byte)(24+Math.Max(0,Motion.Bend)*35),45,34,61));
        dc.DrawEllipse(shadow,null,new Point(175,351),f*(.325+.10*Math.Max(0,Motion.Bend)),3);
        double rock=GptMusicMotion.Clamp(Motion.Rock,-7.5,7.5),other=GptMusicMotion.Clamp(-.94*(Motion.Rock-Motion.RockSpeed*.022),-7.5,7.5);
        DrawSpeaker(dc,-f*.56,rock,f/132);DrawSpeaker(dc,f*.56,other,f/132);dc.Pop();
    }
    void DrawSpeaker(DrawingContext dc,double x,double angle,double scale) {
        double lift=(angle>=0?28:25)*scale*Math.Abs(Math.Sin(angle*Math.PI/180));
        dc.PushTransform(new TranslateTransform(175+x,350-lift));dc.PushTransform(new RotateTransform(angle));dc.PushTransform(new ScaleTransform(scale,scale));
        dc.DrawRoundedRectangle(Shell,TrimPen,new Rect(-25,-90,49,90),8,8);dc.DrawRoundedRectangle(Shell,new Pen(Side,1),new Rect(-21,-86,41,82),5,5);
        dc.DrawRoundedRectangle(Led,null,new Rect(-16,-81,30,3.5),1.7,1.7);
        dc.DrawEllipse(Side,new Pen(Trim,1.8),new Point(0,-63),8,8);dc.DrawEllipse(Core,null,new Point(0,-63),4.5,4.5);
        dc.DrawEllipse(Side,LedPen,new Point(0,-28),18,18);double s=1+Motion.Pulse*.065;
        dc.DrawEllipse(Cone,new Pen(Trim,1),new Point(0,-28),14*s,14*s);dc.DrawEllipse(Core,null,new Point(0,-28),7*s,7*s);
        dc.DrawLine(new Pen(Trim,1),new Point(-13,-7),new Point(12,-7));dc.Pop();dc.Pop();dc.Pop();
    }
    void DrawOver(DrawingContext dc) {
        double p=appearanceReady?1:Motion.Props;if(p<=0)return;dc.PushTransform(new ScaleTransform(1,1-Motion.Bend,175,350));dc.PushOpacity(p);
        if(ColorEnabled) {
            var flow=new LinearGradientBrush();for(int i=0;i<palette.Length;i++)flow.GradientStops.Add(new GradientStop(palette[i],(double)i/(palette.Length-1)));
            flow.StartPoint=new Point(0,.5);flow.EndPoint=new Point(1,.5);flow.SpreadMethod=GradientSpreadMethod.Repeat;flow.RelativeTransform=new TranslateTransform(-(colorTime/2.6%1),0);
            var imageBrush=new ImageBrush(girl.Source){Stretch=Stretch.Uniform,ViewportUnits=BrushMappingMode.Absolute,Viewport=imageRect};
            dc.PushOpacity(.27);dc.PushOpacityMask(imageBrush);dc.DrawRectangle(flow,null,imageRect);dc.Pop();dc.Pop();
            if(glasses){
                var face=new RadialGradientBrush();face.Center=face.GradientOrigin=new Point((alpha.Left+alpha.Width*.508)/girl.Width,(alpha.Top+alpha.Height*.70)/girl.Height);
                face.RadiusX=alpha.Width*.215/girl.Width;face.RadiusY=alpha.Height*.151/girl.Height;
                face.GradientStops.Add(new GradientStop(Color.FromArgb(245,255,255,255),0));face.GradientStops.Add(new GradientStop(Color.FromArgb(220,255,255,255),.65));face.GradientStops.Add(new GradientStop(Colors.Transparent,1));
                dc.PushOpacityMask(face);dc.DrawImage(girl.Source,imageRect);dc.Pop();
            }
        }
        if(glasses) {
            dc.PushTransform(new TranslateTransform(175+alpha.Width*.008,350-alpha.Height*.376));dc.PushTransform(new RotateTransform(-7));dc.PushTransform(new ScaleTransform(alpha.Width/256,alpha.Width/256));
            dc.DrawGeometry(null,Arm,Arms);dc.DrawGeometry(Lens,LensRim,LeftLens);dc.DrawGeometry(Lens,LensRim,RightLens);
            dc.PushOpacity(.30);var shine=new Pen(Brush("#c4cfdf"),1.9);dc.DrawLine(shine,new Point(-47,-6),new Point(-34,-7));dc.DrawLine(shine,new Point(20,-5),new Point(29,-6));dc.Pop();dc.Pop();dc.Pop();dc.Pop();
        }
        dc.Pop();dc.Pop();
    }
    sealed class MusicLamp : FrameworkElement {
        readonly GptMusicVisual owner;public double Diameter=56,Top=52;
        readonly Brush[] beams;readonly Brush halo,leftWash,rightWash;
        static readonly Geometry Fan=Geometry.Parse("M 0,0 L -.30,1 L .30,1 Z");
        static RadialGradientBrush Glow(Color c){var b=new RadialGradientBrush();b.GradientStops.Add(new GradientStop(c,0));b.GradientStops.Add(new GradientStop(Color.FromArgb((byte)(c.A/2),c.R,c.G,c.B),.45));b.GradientStops.Add(new GradientStop(Color.FromArgb(0,c.R,c.G,c.B),1));b.Freeze();return b;}
        static LinearGradientBrush Beam(Color c){var b=new LinearGradientBrush(c,Color.FromArgb(0,c.R,c.G,c.B),90);b.Freeze();return b;}
        public MusicLamp(GptMusicVisual owner){
            this.owner=owner;IsHitTestVisible=false;
            beams=new Brush[]{Beam(Color.FromArgb(110,246,72,197)),Beam(Color.FromArgb(95,72,222,245)),Beam(Color.FromArgb(100,174,100,253))};
            halo=Glow(Color.FromArgb(220,147,228,255));leftWash=Glow(Color.FromArgb(65,40,205,240));rightWash=Glow(Color.FromArgb(75,224,55,197));
        }
        void DrawRoom(DrawingContext dc,GptMusicMotion m,double scale){
            dc.DrawEllipse(leftWash,null,new Point(Width*.05,Height*.65),Width*.75,Height*.8);
            dc.DrawEllipse(rightWash,null,new Point(Width*.95,Height*.5),Width*.75,Height*.8);
            double length=Math.Max(1,Height-Top),brightness=.62;
            dc.PushOpacity(brightness);dc.PushTransform(new TranslateTransform(Width/2,Top+44*scale));
            for(int i=0;i<3;i++){
                double angle=(i-1)*38+14*Math.Sin(Math.PI*m.Cycle*.5+i*1.8)*m.Energy;
                dc.PushTransform(new RotateTransform(angle));dc.PushTransform(new ScaleTransform(length,length));
                dc.DrawGeometry(beams[i],null,Fan);dc.Pop();dc.Pop();
            }
            dc.Pop();dc.Pop();
            dc.PushOpacity(.5+.5*m.Pulse);dc.DrawEllipse(halo,null,new Point(Width/2,Top+44*scale),Diameter*.95,Diameter*.95);dc.Pop();
        }
        protected override void OnRender(DrawingContext dc) {
            var m=owner.Motion;if(m==null)return;double radius=Diameter/2,s=Diameter/56;
            DrawRoom(dc,m,s);
            dc.PushOpacity(Math.Max(.3,m.Props));dc.PushTransform(new TranslateTransform(Width/2,Top));dc.PushTransform(new RotateTransform(m.Lamp));dc.PushTransform(new ScaleTransform(s,s));
            dc.DrawLine(new Pen(Brush("#aaa0b1"),1),new Point(0,0),new Point(0,16));dc.PushTransform(new TranslateTransform(0,44));
            dc.DrawEllipse(Shell,null,new Point(0,0),28,28);dc.PushClip(new EllipseGeometry(new Point(0,0),28,28));
            double phase=(owner.artTime*4)%5-2.5;
            for(int row=0;row<12;row++)for(int col=0;col<15;col++){
                int index=(row*7+col*3+col/3)%(owner.palette.Length-1);
                dc.DrawRectangle(new SolidColorBrush(owner.palette[index]),null,new Rect(-37.5+col*5+phase,-30+row*5,4.35,4.35));
            }
            var shade=new RadialGradientBrush(Color.FromArgb(0,18,12,27),Color.FromArgb(100,18,12,27));shade.Center=shade.GradientOrigin=new Point(.32,.28);dc.DrawEllipse(shade,null,new Point(),28,28);dc.Pop();
            dc.DrawEllipse(null,new Pen(Trim,1.5),new Point(),28,28);
            var sparkle=Brush("#fff9ff");dc.DrawGeometry(sparkle,null,Geometry.Parse("M -10,-23 L -8,-16 L -1,-14 L -8,-12 L -10,-5 L -12,-12 L -19,-14 L -12,-16 Z"));
            dc.Pop();dc.Pop();dc.Pop();dc.Pop();dc.Pop();
        }
    }
}

static class MusicNative {
    [StructLayout(LayoutKind.Sequential)]public struct Rect{public int Left,Top,Right,Bottom;}
    [StructLayout(LayoutKind.Sequential)]public struct Point{public int X,Y;}
    [DllImport("user32.dll")]public static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out Rect r);
    [DllImport("user32.dll")]public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
    [DllImport("user32.dll")]public static extern bool ShowWindow(IntPtr h,int command);
    [DllImport("user32.dll")]public static extern IntPtr GetWindow(IntPtr h,uint command);
    [DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")]public static extern IntPtr GetWindowLongPtr(IntPtr h,int index);
    [DllImport("dwmapi.dll")]static extern int DwmGetWindowAttribute(IntPtr h,int attr,out Rect r,int size);
    [DllImport("dwmapi.dll")]static extern int DwmGetWindowAttribute(IntPtr h,int attr,out uint value,int size);
    public static IntPtr PreviousVisible(IntPtr h){for(int n=0;n<1000;n++){h=GetWindow(h,3);uint cloak;if(h==IntPtr.Zero||(IsWindowVisible(h)&&(DwmGetWindowAttribute(h,14,out cloak,4)!=0||cloak==0)))return h;}return IntPtr.Zero;}
    public static Rect Frame(IntPtr h){Rect r;if(DwmGetWindowAttribute(h,9,out r,16)!=0)GetWindowRect(h,out r);return r;}
}
