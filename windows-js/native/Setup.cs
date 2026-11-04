using System;using System.IO;using System.Runtime.InteropServices;using System.Text;using System.Web.Script.Serialization;
public static class GptWindowsSetup {
 static string Sid(string user){try{return new System.Security.Principal.NTAccount(user).Translate(typeof(System.Security.Principal.SecurityIdentifier)).Value;}catch{return user;}}
 static dynamic Folder(){dynamic service=Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service"));service.Connect();return service.GetFolder("\\");}
 public static int Main(string[] a){Console.OutputEncoding=new UTF8Encoding(false);object result=new{ok=true};try{string op=a[0];if(op=="task-info"){try{dynamic task=Folder().GetTask(a[1]);dynamic d=task.Definition,x=d.Actions.Item(1);result=new{ok=true,exists=true,xml=(string)task.Xml,command=(string)x.Path,arguments=(string)x.Arguments,directory=(string)x.WorkingDirectory,user=(string)d.Principal.UserId,sid=Sid((string)d.Principal.UserId),state=(int)task.State,logon=(int)d.Principal.LogonType,level=(int)d.Principal.RunLevel,actions=(int)d.Actions.Count};}catch(Exception e){uint code=unchecked((uint)e.HResult);if(code!=2147942402&&code!=2147942403)throw;result=new{ok=true,exists=false};}}
 else if(op=="task-register")Folder().RegisterTask(a[1],File.ReadAllText(a[2]),6,a[3],null,3,null);
 else if(op=="task-stop")Folder().GetTask(a[1]).Stop(0);
 else if(op=="task-start")Folder().GetTask(a[1]).Run(null);
 else if(op=="task-delete")Folder().DeleteTask(a[1],0);
 else if(op=="shortcut-info"){if(!File.Exists(a[1]))result=new{ok=true,exists=false};else{dynamic shell=Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));dynamic l=shell.CreateShortcut(a[1]);result=new{ok=true,exists=true,target=(string)l.TargetPath,arguments=(string)l.Arguments,directory=(string)l.WorkingDirectory};}}
 else if(op=="shortcut-write"){dynamic shell=Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));dynamic l=shell.CreateShortcut(a[1]);l.TargetPath=a[2];l.Arguments=a[3];l.WorkingDirectory=a[4];l.Description="GPT Niang: Codex subscription quota widget";l.Save();}
 else throw new ArgumentException("Unknown setup operation");Console.WriteLine(new JavaScriptSerializer().Serialize(result));return 0;
 }catch(Exception e){Console.WriteLine(new JavaScriptSerializer().Serialize(new{ok=false,error=e.Message,code=e.HResult}));return 1;}}
}
