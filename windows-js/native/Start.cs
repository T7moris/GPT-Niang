using System;using System.Diagnostics;using System.IO;using System.Reflection;using System.Collections.Generic;using System.Web.Script.Serialization;using System.Threading.Tasks;using System.Text;
public static class GptStart {
 static string Quote(string value){return "\""+value+"\"";}
 static bool Same(string a,string b){return String.Equals(Path.GetFullPath(a),Path.GetFullPath(b),StringComparison.OrdinalIgnoreCase);}
 static Dictionary<string,object> Read(string file,JavaScriptSerializer json){return json.Deserialize<Dictionary<string,object>>(File.ReadAllText(file));}
 static void Forward(Stream source,Stream destination){byte[] buffer=new byte[8192];int count;while((count=source.Read(buffer,0,buffer.Length))>0){destination.Write(buffer,0,count);destination.Flush();}}
 static int Mcp(string cachedRoot){
  var json=new JavaScriptSerializer();var cached=Read(Path.Combine(cachedRoot,"installation.json"),json);
  string root=Path.GetFullPath(Convert.ToString(cached["appDir"])),data=Path.GetFullPath(Convert.ToString(cached["dataDir"]));
  var current=Read(Path.Combine(root,"installation.json"),json);
  if(!Same(Convert.ToString(current["appDir"]),root)||!Same(Convert.ToString(current["dataDir"]),data)||Convert.ToString(current["architecture"])!="javascript-electron"||(current.ContainsKey("candidate")&&Object.Equals(current["candidate"],true)))throw new Exception("MCP installation binding mismatch");
  string node=current.ContainsKey("nodePath")?Convert.ToString(current["nodePath"]):null;
  if(String.IsNullOrEmpty(node)||!File.Exists(node))node=Path.Combine(root,"node_modules","electron","dist","electron.exe");
  var start=new ProcessStartInfo(node);start.Arguments=Quote(Path.Combine(root,"runtime","mcp.mjs"));start.WorkingDirectory=root;start.UseShellExecute=false;start.CreateNoWindow=true;start.WindowStyle=ProcessWindowStyle.Hidden;
  start.RedirectStandardInput=true;start.RedirectStandardOutput=true;start.RedirectStandardError=true;
  if(String.Equals(Path.GetFileName(node),"electron.exe",StringComparison.OrdinalIgnoreCase))start.EnvironmentVariables["ELECTRON_RUN_AS_NODE"]="1";else start.EnvironmentVariables.Remove("ELECTRON_RUN_AS_NODE");
  if(current.ContainsKey("codexHome")&&!String.IsNullOrEmpty(Convert.ToString(current["codexHome"])))start.EnvironmentVariables["CODEX_HOME"]=Convert.ToString(current["codexHome"]);
  using(var child=Process.Start(start)){
   Task.Factory.StartNew(()=>{try{Forward(Console.OpenStandardInput(),child.StandardInput.BaseStream);}catch(IOException){}catch(ObjectDisposedException){}finally{try{child.StandardInput.Close();}catch(ObjectDisposedException){}}});
   var output=Task.Factory.StartNew(()=>{Forward(child.StandardOutput.BaseStream,Console.OpenStandardOutput());});
   var error=Task.Factory.StartNew(()=>{Forward(child.StandardError.BaseStream,Console.OpenStandardError());});
   child.WaitForExit();Task.WaitAll(output,error);return child.ExitCode;
  }
 }
 static bool OwnerAlive(Dictionary<string,object> record){
  try{
   int pid=Convert.ToInt32(record["ownerPid"]);if(pid<=0)return false;using(var process=Process.GetProcessById(pid)){
    if(process.HasExited)return false;
    if(!record.ContainsKey("ownerStartedTicks")||record["ownerStartedTicks"]==null)return true;
    return process.StartTime.ToUniversalTime().Ticks.ToString()==Convert.ToString(record["ownerStartedTicks"]);
   }
  }catch(ArgumentException){return false;}catch{return true;}
 }
 static bool RecoverInstall(string data,string root,string[] args,JavaScriptSerializer json){
  string file=Path.Combine(data,"javascript-install-journal.json");if(!File.Exists(file))return false;
  var journal=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(file));
  if(Convert.ToInt32(journal["schema"])!=1||!Same(Convert.ToString(journal["root"]),root)||!Same(Convert.ToString(journal["dataDir"]),data))throw new Exception("Install recovery binding mismatch");
  string phase=Convert.ToString(journal["phase"]);if(phase=="committed"||phase=="rolled-back")return false;
  if(OwnerAlive(journal))return phase!="waiting-health";
  if(!journal.ContainsKey("recovery")||journal["recovery"]==null)return false;
  string token=Convert.ToString(journal["token"]);Guid parsed;if(!Guid.TryParse(token,out parsed))throw new Exception("Invalid install recovery token");
  var recovery=(Dictionary<string,object>)journal["recovery"];
  string agent=Path.GetFullPath(Convert.ToString(recovery["agent"])),script=Path.GetFullPath(Convert.ToString(recovery["script"]));
  if(!Same(agent,Path.Combine(data,"install-js-"+token,"recovery"))||!Same(script,Path.Combine(agent,"src","install-recovery.mjs")))throw new Exception("Install recovery path mismatch");
  var start=new ProcessStartInfo(Convert.ToString(recovery["executable"]));start.UseShellExecute=false;start.CreateNoWindow=true;start.WindowStyle=ProcessWindowStyle.Hidden;start.WorkingDirectory=data;start.EnvironmentVariables["ELECTRON_RUN_AS_NODE"]="1";
  start.Arguments=Quote(script)+" "+Quote(data)+" "+Quote(token)+" --launcher-resume";Process.Start(start);return true;
 }
 static void Drain(StreamReader reader,StringBuilder errors){
  char[] bytes=new char[2048];int count;
  while((count=reader.Read(bytes,0,bytes.Length))>0)if(errors!=null){lock(errors){errors.Append(bytes,0,count);if(errors.Length>16384)errors.Remove(0,errors.Length-16384);}}
 }
 static int Supervise(ProcessStartInfo start,string diagnostic){
  try{File.Delete(diagnostic);}catch{}
  start.RedirectStandardInput=true;start.RedirectStandardOutput=true;start.RedirectStandardError=true;
  start.StandardOutputEncoding=Encoding.UTF8;start.StandardErrorEncoding=Encoding.UTF8;
  using(var child=Process.Start(start)){
   child.StandardInput.Close();var errors=new StringBuilder();
   var output=Task.Factory.StartNew(()=>Drain(child.StandardOutput,null));
   var error=Task.Factory.StartNew(()=>Drain(child.StandardError,errors));
   child.WaitForExit();Task.WaitAll(output,error);
   if(child.ExitCode!=0)try{lock(errors)File.WriteAllText(diagnostic,"Supervisor exit code: "+child.ExitCode+Environment.NewLine+errors,new UTF8Encoding(false));}catch{}
   return child.ExitCode;
  }
 }
 public static int Main(string[] args){
  string directory=Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
  string root=Path.GetDirectoryName(directory);
  if(args.Length==1&&args[0]=="--mcp"){
   try{return Mcp(root);}catch(Exception error){Console.Error.WriteLine("GPT Niang MCP startup failed: "+error.Message);return 1;}
  }
  bool candidate=Array.IndexOf(args,"--candidate")>=0;
  Guid restartToken;bool restart=args.Length==2&&args[0]=="--restart-helper"&&Guid.TryParse(args[1],out restartToken);
  try{
   string bindingFile=Path.Combine(directory,"launcher.json");
   if(!candidate&&File.Exists(bindingFile)){
    var json=new JavaScriptSerializer();var binding=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(bindingFile));
    root=Path.GetFullPath(Convert.ToString(binding["appDir"]));string data=Path.GetFullPath(Convert.ToString(binding["dataDir"]));
    if(!restart&&RecoverInstall(data,root,args,json))return 0;
    string journalFile=Path.Combine(data,"javascript-update-journal.json");
    if(!restart&&File.Exists(journalFile)){
     var journal=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(journalFile));string phase=Convert.ToString(journal["phase"]);
     if(phase!="committed"&&phase!="rolled-back"){
      string agent=Path.GetFullPath(Convert.ToString(journal["agent"])),job=Path.GetFullPath(Convert.ToString(journal["job"]));
      if(!agent.StartsWith(Path.Combine(data,"update-agent-js")+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase)||!String.Equals(job,Path.Combine(agent,"job.json"),StringComparison.OrdinalIgnoreCase)||!String.Equals(root,Path.GetFullPath(Convert.ToString(journal["root"])),StringComparison.OrdinalIgnoreCase))throw new Exception("Update recovery binding mismatch");
      var recover=new ProcessStartInfo(Convert.ToString(journal["executable"]));recover.UseShellExecute=false;recover.CreateNoWindow=true;recover.WindowStyle=ProcessWindowStyle.Hidden;recover.WorkingDirectory=agent;recover.EnvironmentVariables["ELECTRON_RUN_AS_NODE"]="1";
      recover.Arguments=Quote(Path.Combine(agent,"src","update-agent.mjs"))+" "+Quote(job)+" --recover --launcher-resume";foreach(string arg in args)recover.Arguments+=" "+Quote(arg);Process.Start(recover);return 0;
     }
    }
   }
  }catch(Exception e){try{File.AppendAllText(Path.Combine(directory,"launcher-error.txt"),e.ToString());}catch{}return 1;}
  var start=new ProcessStartInfo(Path.Combine(root,"node_modules","electron","dist","electron.exe"));
  start.Arguments=Quote(candidate?root:Path.Combine(root,"src",restart?"restart-entry.mjs":"start.mjs"));
  foreach(string arg in args)start.Arguments+=" "+Quote(arg);
  start.WorkingDirectory=root;start.UseShellExecute=false;start.CreateNoWindow=true;
  if(candidate){start.WindowStyle=ProcessWindowStyle.Normal;start.EnvironmentVariables.Remove("ELECTRON_RUN_AS_NODE");}
  else{start.WindowStyle=ProcessWindowStyle.Hidden;start.EnvironmentVariables["ELECTRON_RUN_AS_NODE"]="1";}
  try{
   if(restart)return Supervise(start,Path.Combine(directory,"restart-launch-error.txt"));
   if(!candidate&&Array.IndexOf(args,"--supervise")>=0)return Supervise(start,Path.Combine(directory,"supervisor-launch-error.txt"));
   Process.Start(start);return 0;
  }catch(Exception e){try{File.AppendAllText(Path.Combine(directory,"launcher-error.txt"),e.ToString());}catch{}return 1;}
 }
}
