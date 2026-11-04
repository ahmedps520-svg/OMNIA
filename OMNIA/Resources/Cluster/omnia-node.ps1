# OMNIA Node for Windows: lends this PC's GPU (or CPU) to an OMNIA cluster on the local network.
#
# The iPad serves this file and shows the command that runs it:
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm http://<iPad>:8770/node.ps1 | iex"
#
# It compiles the program below into %LOCALAPPDATA%\OMNIA\Node, so Windows Firewall asks about
# OMNIA Node rather than PowerShell. The program downloads llama.cpp's official ggml-rpc-server
# for this PC's GPU, checks its SHA-256, runs it on loopback only and relays the iPad's
# connections to it, turning every other address away. Nothing is installed: closing the window
# stops it, and deleting that folder removes it.
#
# No param() block, since it runs through "irm | iex": the iPad fills in the three values below.
# Environment variables override them: OMNIA_HOST, OMNIA_TOKEN, OMNIA_NODE_BACKEND (cuda, vulkan
# or cpu) and OMNIA_NODE_SELFTEST=1 (CI: the CPU build, checked on loopback without an iPad).

$ErrorActionPreference = 'Stop'

$omniaHost = '__OMNIA_HOST__'
$omniaToken = '__OMNIA_TOKEN__'
$omniaCluster = '__OMNIA_CLUSTER_NAME__'

if ($env:OMNIA_HOST) { $omniaHost = $env:OMNIA_HOST }
if ($env:OMNIA_TOKEN) { $omniaToken = $env:OMNIA_TOKEN }
$selfTest = $env:OMNIA_NODE_SELFTEST -eq '1'

if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Host 'OMNIA Node runs in Windows PowerShell: use the command exactly as the iPad shows it.'
    exit 1
}
# A value the iPad didn't fill in still reads like its placeholder.
if (-not $selfTest -and ($omniaHost -like '__OMNIA*' -or $omniaToken -like '__OMNIA*')) {
    Write-Host 'Run the command the iPad shows: it carries the address and code of the cluster.'
    exit 1
}
if ($omniaCluster -like '__OMNIA*') { $omniaCluster = '' }

# NVIDIA GPUs get llama.cpp's CUDA build and other GPUs (AMD, say) its Vulkan build. Intel's and
# Microsoft's adapters, and virtual displays, are better served by the CPU build.
if ($selfTest) {
    $backend = 'cpu'
} elseif ($env:OMNIA_NODE_BACKEND) {
    $backend = $env:OMNIA_NODE_BACKEND.Trim().ToLowerInvariant()
} else {
    $adapters = @()
    try { $adapters = @(Get-CimInstance -ClassName Win32_VideoController | ForEach-Object { [string]$_.Name }) } catch { }
    if ((Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe')) -or ($adapters -match 'NVIDIA')) {
        $backend = 'cuda'
    } elseif ($adapters | Where-Object { $_ -and $_ -notmatch 'Intel|Microsoft|Virtual|Remote|Parsec|Citrix|DisplayLink|VMware' }) {
        $backend = 'vulkan'
    } else {
        $backend = 'cpu'
    }
}
if ($backend -notin 'cuda', 'vulkan', 'cpu') {
    Write-Host "OMNIA_NODE_BACKEND must be cuda, vulkan or cpu, not '$backend'."
    exit 1
}

# Windows blocks other devices on networks it treats as public, a common reason an iPad can't
# reach a PC. The node says so when its route to the iPad goes through one.
$publicNetwork = $false
if (-not $selfTest) {
    try {
        $hostAddress = ([uri]"http://$omniaHost").DnsSafeHost
        $route = @(Find-NetRoute -RemoteIPAddress $hostAddress)[0]
        $connection = @(Get-NetConnectionProfile -InterfaceIndex $route.InterfaceIndex)[0]
        $publicNetwork = [string]$connection.NetworkCategory -eq 'Public'
    } catch { }
}

$nodeFolder = Join-Path $env:LOCALAPPDATA 'OMNIA\Node'
$source = @'
// OMNIA Node: lends this PC's GPU (or CPU) to an OMNIA cluster on the local network.
// omnia-node.ps1 compiles it with Windows PowerShell's Add-Type: C# 5 on .NET Framework 4.5+.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Microsoft.Win32;

// Windows Firewall's prompt and Task Manager show this name instead of the file's.
[assembly: AssemblyTitle("OMNIA Node")]
[assembly: AssemblyProduct("OMNIA")]

namespace OmniaNode
{
    static class Program
    {
        public const string LlamaBuild = "b11960";
        public const int Protocol = 1;
        public const long Mebibyte = 1024 * 1024;

        // Everything the node keeps lives beside it, in %LOCALAPPDATA%\OMNIA\Node.
        public static readonly string Folder = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);

        // Set by Ctrl+C, a closed window, or the host turning this PC away. Every wait watches it.
        public static readonly CancellationTokenSource Stop = new CancellationTokenSource();

        static int Main(string[] args)
        {
            Ui.Start();
            bool selfTest = false;
            int code;
            Mutex single = null;
            try
            {
                Options options = Options.Parse(args);
                selfTest = options.SelfTest;
                ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;  // GitHub requires TLS 1.2
                ServicePointManager.Expect100Continue = false;  // POST bodies go at once, not after a "100 Continue"
                single = AcquireSingleInstance();
                if (single == null) throw new NodeException("OMNIA Node is already running on this PC, in another window.");
                code = selfTest ? SelfTest.Run() : new Node(options).Run();
            }
            catch (OperationCanceledException)
            {
                code = 0;  // Ctrl+C before the node was up
            }
            catch (NodeException e)
            {
                Ui.Line(e.Message);
                code = 1;
            }
            catch (Exception e)
            {
                Ui.Line(selfTest ? e.ToString() : "OMNIA Node stopped after an unexpected error (" + e.GetType().Name + ": " + e.Message + ")");
                code = 1;
            }
            if (single != null)
            {
                single.ReleaseMutex();
                single.Dispose();
            }
            if (code != 0 && !selfTest) Ui.PauseIfWindowCloses();
            Ui.Finish();
            return code;
        }

        // Two nodes on one PC would share an id, and each would stop the other's rpc-server.
        static Mutex AcquireSingleInstance()
        {
            var mutex = new Mutex(false, @"Local\OMNIA-Node");
            try
            {
                if (mutex.WaitOne(TimeSpan.FromSeconds(5))) return mutex;  // a node that's just stopping gets a moment
            }
            catch (AbandonedMutexException)
            {
                return mutex;  // its last owner ended without releasing it; it's ours now
            }
            mutex.Dispose();
            return null;
        }

        // For the main thread's waits: a stop request unwinds it from wherever it is.
        public static void Pause(int milliseconds)
        {
            if (Stop.Token.WaitHandle.WaitOne(milliseconds)) throw new OperationCanceledException();
        }

        // For background threads: true when the node is stopping.
        public static bool WaitForStop(int milliseconds)
        {
            return Stop.Token.WaitHandle.WaitOne(milliseconds);
        }
    }

    // A failure explained for the person at the PC; printed as is.
    sealed class NodeException : Exception
    {
        public NodeException(string message) : base(message) { }
    }

    // What omnia-node.ps1 passes. Values arrive as --name=<base64 of UTF-8>, which no cluster name
    // can break: Windows PowerShell passes quotes and empty strings to programs badly.
    sealed class Options
    {
        public string Host = "";
        public string Token = "";
        public string Cluster = "";
        public string Backend = "cpu";
        public bool PublicNetwork;
        public bool SelfTest;

        public static Options Parse(string[] args)
        {
            var options = new Options();
            foreach (string arg in args)
            {
                int split = arg.IndexOf('=');
                string name = split < 0 ? arg : arg.Substring(0, split);
                string value = split < 0 ? "" : Encoding.UTF8.GetString(Convert.FromBase64String(arg.Substring(split + 1)));
                if (name == "--host") options.Host = value.Trim();
                else if (name == "--token") options.Token = value.Trim();
                else if (name == "--cluster") options.Cluster = value.Trim();
                else if (name == "--backend") options.Backend = value;
                else if (name == "--public-network") options.PublicNetwork = true;
                else if (name == "--self-test") options.SelfTest = true;
                else throw new NodeException("OMNIA Node doesn't know the argument " + arg + ".");
            }
            return options;
        }
    }

    // Lends this PC to the cluster until Ctrl+C, a closed window, or the host turns it away.
    sealed class Node
    {
        enum State { Connecting, Unreachable, Pending, Connected, Lost }

        readonly Options options;
        readonly HostClient host;
        readonly IPAddress[] hostAddresses;  // OMNIA_HOST's address; the join reply adds the iPad's others
        readonly object shutdownGate = new object();
        bool shutDown;
        NativeMethods.ConsoleCtrlHandler closeHandler;  // a field, so it outlives its registration

        string id, platform, build, backendName;
        volatile string cluster;
        volatile State state = State.Connecting;
        volatile RpcServerProcess rpc;
        volatile Relay relay;
        volatile bool registered;  // the host knows this node: joined, or waiting for approval
        volatile int exitCode;
        volatile int heartbeatMilliseconds = 3000;
        double lastRequestMilliseconds;
        DateTime rpcStarted;

        public Node(Options options)
        {
            this.options = options;
            if (options.Host.Length == 0 || options.Token.Length == 0)
                throw new NodeException("Run the command the iPad shows: it carries the address and code of the cluster.");
            host = new HostClient(options.Host);
            hostAddresses = host.Addresses();
            cluster = options.Cluster.Length > 0 ? options.Cluster : "the iPad";
        }

        public int Run()
        {
            try
            {
                HandleStopRequests();
                Lend();
                return exitCode;
            }
            finally
            {
                Shutdown();
            }
        }

        void Lend()
        {
            id = LoadId();
            platform = Machine.Platform();
            RpcServerProcess.StopLeftovers();
            build = Downloader.Prepare(options.Backend);
            StartRpcServer();
            List<Device> devices = rpc.Devices;
            backendName = BackendName(options.Backend, devices);

            Ui.Line("");
            Ui.Line("OMNIA Node - lends this PC's " + Describe(devices) + " to " + cluster);
            if (options.Backend == "cuda" && backendName == "CPU")
                Ui.Line("llama.cpp can't use the NVIDIA GPU (an NVIDIA driver update usually fixes that), so this PC lends its CPU.");
            if (options.Backend == "vulkan" && backendName == "CPU")
                Ui.Line("llama.cpp can't use this PC's GPU (a graphics driver update may fix that), so this PC lends its CPU.");
            if (options.PublicNetwork)
                Ui.Line("Keep this window open. Windows treats this network as public: if it asks about network access, allow public networks, or set this network to Private in Settings.");
            else
                Ui.Line("Keep this window open. If Windows asks about network access, allow it on private networks.");
            Ui.Line("Press Ctrl+C to stop lending this PC.");
            Ui.Line("");

            relay = Relay.Start(rpc.Port);
            relay.SetAllowed(hostAddresses);
            var talk = new Thread(TalkToHost);
            talk.IsBackground = true;
            talk.Start();
            Watch();

            if (exitCode == 0)
            {
                Ui.ClearStatus();
                Ui.Line("Stopping...");
                Shutdown();
                Ui.Line("Stopped. This PC is no longer lent to " + cluster + ".");
            }
        }

        // The main thread: the status line and rpc-server's health, every two seconds.
        void Watch()
        {
            long lastBytes = 0;
            double lastSeconds = 0;
            Stopwatch clock = Stopwatch.StartNew();
            Ui.Status(StatusText(0));
            while (!Program.WaitForStop(2000))
            {
                KeepRpcServerRunning();
                long bytes = relay.BytesRelayed;
                double seconds = clock.Elapsed.TotalSeconds;
                double rate = (bytes - lastBytes) / Math.Max(0.1, seconds - lastSeconds);
                lastBytes = bytes;
                lastSeconds = seconds;
                Ui.Status(StatusText(rate));
            }
        }

        string StatusText(double bytesPerSecond)
        {
            switch (state)
            {
                case State.Connected:
                    if (!relay.Busy) return "Connected to " + cluster + " - idle";
                    if (bytesPerSecond < 50000) return "Connected to " + cluster + " - in use";
                    return "Connected to " + cluster + " - working, " + (bytesPerSecond / 1e6).ToString("0.0", CultureInfo.InvariantCulture) + " MB/s";
                case State.Pending:
                    return "Waiting for approval on " + cluster + "...";
                case State.Unreachable:
                    return "Waiting for " + cluster + " at " + options.Host + "...";
                case State.Lost:
                    return "Waiting for " + options.Host + "...";
                default:
                    return "Connecting to " + cluster + "...";
            }
        }

        void StartRpcServer()
        {
            Ui.Status("Starting llama.cpp's rpc-server...");
            rpc = RpcServerProcess.Start(build);
            rpcStarted = DateTime.UtcNow;
            Ui.ClearStatus();
        }

        // rpc-server can stop on its own (a CUDA error aborts it): start it again, unless it keeps
        // stopping. The iPad sees its connection drop and reconnects.
        void KeepRpcServerRunning()
        {
            if (!rpc.HasExited) return;
            Ui.Line("llama.cpp's rpc-server stopped:" + rpc.Tail(6));
            if (DateTime.UtcNow - rpcStarted < TimeSpan.FromMinutes(1))
                throw new NodeException("rpc-server keeps stopping, so OMNIA Node stops too.");
            rpc.Dispose();
            StartRpcServer();
            relay.TargetPort = rpc.Port;
            Ui.Line("Restarted rpc-server.");
        }

        // The host thread: join, then heartbeat, and join again whenever the host has forgotten
        // this node (the iPad restarted the cluster). The status line reads its state.
        void TalkToHost()
        {
            try
            {
                while (Join()) Heartbeat();
            }
            catch (Exception e)
            {
                exitCode = 1;
                Ui.Line("OMNIA Node stopped after an unexpected error (" + e.GetType().Name + ": " + e.Message + ")");
                Program.Stop.Cancel();
            }
        }

        // True once joined; false when the node is stopping or the host turned it away.
        bool Join()
        {
            bool toldPending = false, toldUnreachable = false;
            DateTime firstTry = DateTime.UtcNow;
            while (!Program.Stop.IsCancellationRequested)
            {
                Reply reply = host.Post("/v1/join", JoinBody(), 5000);
                if (Program.Stop.IsCancellationRequested) return false;
                lastRequestMilliseconds = reply.Milliseconds;
                int status = reply.Status;
                if (reply.Text("cluster") != null) cluster = reply.Text("cluster");
                if (status == 200)
                {
                    Joined(reply);
                    return true;
                }
                if (status == 202)
                {
                    // A PC the iPad hasn't seen before needs one tap of approval there.
                    registered = true;
                    state = State.Pending;
                    if (!toldPending) Ui.Line(reply.Text("message") ?? "Waiting for approval on " + cluster + ": tap Allow on the iPad.");
                    toldPending = true;
                    if (Program.WaitForStop(3000)) return false;
                    continue;
                }
                if (status == 403 || status == 409 || status == 426)
                {
                    Refuse(reply.Text("error") ?? RefusalText(status), 2);
                    return false;
                }
                if (status >= 400 && status < 500 && status != 404 && status != 408 && status != 429)
                {
                    Refuse(reply.Text("error") ?? cluster + " turned this PC away (HTTP " + status + ").", 1);
                    return false;
                }
                // No answer, or no cluster yet: the iPad may not have started it.
                state = State.Unreachable;
                if (!toldUnreachable && DateTime.UtcNow - firstTry > TimeSpan.FromSeconds(30))
                {
                    Ui.Line("No answer from " + cluster + " at " + options.Host + " yet. Check that OMNIA is open there and that this PC is on the same network.");
                    toldUnreachable = true;
                }
                if (Program.WaitForStop(5000)) return false;
            }
            return false;
        }

        void Joined(Reply reply)
        {
            var allowed = new List<IPAddress>(hostAddresses);
            foreach (object item in reply.List("hostAddresses"))
            {
                IPAddress address;
                if (IPAddress.TryParse(item as string, out address)) allowed.Add(address);
            }
            relay.SetAllowed(allowed);
            heartbeatMilliseconds = (int)(Math.Max(1, Math.Min(30, reply.Number("heartbeatSeconds", 3))) * 1000);
            registered = true;
            state = State.Connected;
        }

        // Returns when the host has forgotten this node (join again), or when the node stops.
        void Heartbeat()
        {
            while (!Program.WaitForStop(heartbeatMilliseconds))
            {
                Reply reply = host.Post("/v1/heartbeat", HeartbeatBody(), 5000);
                if (Program.Stop.IsCancellationRequested) return;
                if (reply.Status == 200)
                {
                    lastRequestMilliseconds = reply.Milliseconds;
                    state = State.Connected;
                }
                else if (reply.Status == 404)
                {
                    state = State.Connecting;
                    return;
                }
                else if (reply.Status == 403)
                {
                    Refuse("This cluster's code changed. Run the new command shown on the iPad.", 2);
                    return;
                }
                else
                {
                    state = State.Lost;  // network trouble: keep trying quietly
                }
            }
        }

        // Exit code 2 tells scripts the host turned this PC away.
        void Refuse(string message, int code)
        {
            registered = false;  // nothing to leave
            exitCode = code;
            Ui.ClearStatus();
            Ui.Line(message);
            Program.Stop.Cancel();
        }

        string RefusalText(int status)
        {
            if (status == 409) return cluster + " is full.";
            if (status == 426) return "This copy of OMNIA Node doesn't match " + cluster + ". Run the command shown on the iPad again.";
            return cluster + " didn't accept this PC's code. Run the command shown on the iPad again.";
        }

        Dictionary<string, object> Body()
        {
            var body = new Dictionary<string, object>();
            body["protocol"] = Program.Protocol;
            body["token"] = options.Token;
            body["id"] = id;
            return body;
        }

        Dictionary<string, object> JoinBody()
        {
            var devices = new List<object>();
            foreach (Device device in rpc.Devices)
            {
                var entry = new Dictionary<string, object>();
                entry["index"] = device.Index;
                entry["name"] = device.Name;
                entry["description"] = device.Description;
                entry["memoryTotal"] = device.MemoryTotal;
                entry["memoryFree"] = device.MemoryFree;
                devices.Add(entry);
            }
            var worker = new Dictionary<string, object>();
            worker["id"] = id;
            worker["name"] = Environment.MachineName;
            worker["kind"] = "pc";
            worker["platform"] = platform;
            worker["rpcPort"] = relay.Port;
            worker["llamaBuild"] = Program.LlamaBuild;
            worker["backend"] = backendName;
            worker["memoryRAM"] = Machine.TotalMemory();
            worker["devices"] = devices;
            var body = new Dictionary<string, object>();
            body["protocol"] = Program.Protocol;
            body["token"] = options.Token;
            body["worker"] = worker;
            return body;
        }

        Dictionary<string, object> HeartbeatBody()
        {
            Dictionary<string, object> body = Body();
            body["rttMs"] = Math.Round(lastRequestMilliseconds, 1);
            body["busy"] = relay.Busy;
            if (backendName == "CUDA")
            {
                List<object> devices = NvidiaSmi.FreeMemory(rpc.Devices);
                if (devices != null) body["devices"] = devices;
            }
            return body;
        }

        void HandleStopRequests()
        {
            try
            {
                Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs e)
                {
                    // The first Ctrl+C stops cleanly (leaving the cluster); a second one doesn't wait.
                    e.Cancel = !Program.Stop.IsCancellationRequested;
                    Program.Stop.Cancel();
                };
            }
            catch (IOException) { }  // no console
            closeHandler = delegate(int type)
            {
                if (type != NativeMethods.CtrlClose && type != NativeMethods.CtrlLogoff && type != NativeMethods.CtrlShutdown) return false;
                Shutdown();  // Windows ends the process as soon as this returns
                return true;
            };
            NativeMethods.SetConsoleCtrlHandler(closeHandler, true);
        }

        // Leaves the cluster and stops the relay and rpc-server, once: on the main thread, or on the
        // close handler's when the window closes. A second caller waits until it's done.
        void Shutdown()
        {
            lock (shutdownGate)
            {
                if (shutDown) return;
                shutDown = true;
                Program.Stop.Cancel();
                if (registered) host.Post("/v1/leave", Body(), 1500);
                if (relay != null) relay.Stop();
                if (rpc != null) rpc.Dispose();
            }
        }

        // The id the iPad knows this PC by (it remembers approved PCs by it), created once.
        static string LoadId()
        {
            string path = Path.Combine(Program.Folder, "node-id.txt");
            Guid id;
            if (File.Exists(path) && Guid.TryParse(File.ReadAllText(path).Trim(), out id)) return id.ToString().ToUpperInvariant();
            string fresh = Guid.NewGuid().ToString().ToUpperInvariant();
            File.WriteAllText(path, fresh);
            return fresh;
        }

        static string BackendName(string backend, List<Device> devices)
        {
            if (backend == "cuda" && devices.Any(d => d.Name.StartsWith("CUDA", StringComparison.Ordinal))) return "CUDA";
            if (backend == "vulkan" && devices.Any(d => d.Name.StartsWith("Vulkan", StringComparison.Ordinal))) return "Vulkan";
            return "CPU";
        }

        // "NVIDIA GeForce RTX 4060 Ti (16 GB)", "2 x NVIDIA GeForce RTX 3090 (48 GB)".
        static string Describe(List<Device> devices)
        {
            IEnumerable<string> names = devices.GroupBy(d => d.Description)
                .Select(g => g.Count() > 1 ? g.Count() + " x " + g.Key : g.Key);
            double gigabytes = Math.Max(1, Math.Round(devices.Sum(d => d.MemoryTotal) / 1073741824.0));
            return string.Join(" + ", names) + " (" + gigabytes.ToString("0", CultureInfo.InvariantCulture) + " GB)";
        }
    }

    // One device rpc-server serves, as it listed it at startup.
    sealed class Device
    {
        // ggml-rpc prints each device as "  %s: %s (%zu MiB, %zu MiB free)".
        static readonly Regex Listing = new Regex(@"^\s+(\S+): (.+) \((\d+) MiB, (\d+) MiB free\)\s*$");

        public int Index;
        public string Name;         // "CUDA0"
        public string Description;  // "NVIDIA GeForce RTX 4060 Ti"
        public long MemoryTotal;    // bytes
        public long MemoryFree;     // bytes

        public static Device Parse(string line, int index)
        {
            Match match = Listing.Match(line);
            if (!match.Success) return null;
            var device = new Device();
            device.Index = index;
            device.Name = match.Groups[1].Value;
            device.Description = match.Groups[2].Value.Trim();
            device.MemoryTotal = long.Parse(match.Groups[3].Value, CultureInfo.InvariantCulture) * Program.Mebibyte;
            device.MemoryFree = long.Parse(match.Groups[4].Value, CultureInfo.InvariantCulture) * Program.Mebibyte;
            return device;
        }
    }

    // llama.cpp's rpc-server, listening on loopback only: it trusts every client, so the relay is
    // the only way in from the network.
    sealed class RpcServerProcess : IDisposable
    {
        const int FirstPort = 50152, LastPort = 50161;
        enum Outcome { Ready, PortTaken, Failed }

        public readonly int Port;
        readonly Process process;
        readonly object gate = new object();
        readonly List<string> output = new List<string>();  // its latest lines, for error reports
        readonly List<Device> devices = new List<Device>();
        bool listing, listed;

        RpcServerProcess(string exe, int port)
        {
            Port = port;
            var info = new ProcessStartInfo(exe, "-H 127.0.0.1 -p " + port.ToString(CultureInfo.InvariantCulture) + " -c");
            info.WorkingDirectory = Path.GetDirectoryName(exe);
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            info.StandardOutputEncoding = Encoding.UTF8;
            info.StandardErrorEncoding = Encoding.UTF8;
            // -c keeps uploaded weights in %LLAMA_CACHE%\rpc, so a model the iPad loads again comes
            // from this PC's disk instead of over Wi-Fi.
            info.EnvironmentVariables["LLAMA_CACHE"] = Path.Combine(Program.Folder, "cache");
            process = new Process();
            process.StartInfo = info;
            process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { Read(e.Data); };
            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { Read(e.Data); };
            process.Start();
            ChildJob.Add(process);
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
        }

        public List<Device> Devices
        {
            get { lock (gate) return new List<Device>(devices); }
        }

        public bool HasExited
        {
            get { return process.HasExited; }
        }

        // Starts rpc-server on the first free port it can bind, once it has listed its devices
        // and answers HELLO.
        public static RpcServerProcess Start(string build)
        {
            string exe = Directory.GetFiles(build, "ggml-rpc-server.exe", SearchOption.AllDirectories).FirstOrDefault();
            if (exe == null)
                throw new NodeException("The llama.cpp build in " + build + " has no ggml-rpc-server.exe. Delete that folder, then run the command again.");
            for (int port = FirstPort; port <= LastPort; port++)
            {
                if (!PortIsFree(port)) continue;
                var server = new RpcServerProcess(exe, port);
                Outcome outcome;
                try
                {
                    outcome = server.WaitUntilReady();
                }
                catch
                {
                    server.Dispose();
                    throw;
                }
                if (outcome == Outcome.Ready) return server;
                server.Dispose();
                if (outcome == Outcome.Failed)
                    throw new NodeException("llama.cpp's rpc-server didn't start:" + server.Tail(12));
            }
            throw new NodeException("Ports " + FirstPort + " to " + LastPort + " are all taken on this PC, so rpc-server has nowhere to listen.");
        }

        Outcome WaitUntilReady()
        {
            // The list is complete when rpc-server goes on to its transport; it binds the port next.
            Stopwatch clock = Stopwatch.StartNew();
            while (!process.HasExited && !Listed && clock.Elapsed < TimeSpan.FromSeconds(60)) Program.Pause(100);
            if (!process.HasExited && Devices.Count > 0)
            {
                // A taken port shows as rpc-server exiting right away ("Failed to create server socket").
                for (int i = 0; i < 20 && !process.HasExited; i++) Program.Pause(100);
                if (!process.HasExited)
                {
                    Version version = RpcHello.Ask(Port, 5000);
                    return version != null && version.Major == 8 ? Outcome.Ready : Outcome.Failed;
                }
            }
            if (!process.HasExited) return Outcome.Failed;  // no device within a minute
            process.WaitForExit();  // until its output has been read too
            return Said("Failed to create server socket") ? Outcome.PortTaken : Outcome.Failed;
        }

        bool Listed
        {
            get { lock (gate) return listed; }
        }

        // ggml logs to stderr: "Devices:", a line per device (backends may log in between), then
        // "  transport      : TCP".
        void Read(string line)
        {
            if (line == null) return;
            lock (gate)
            {
                output.Add(line);
                if (output.Count > 200) output.RemoveAt(0);
                if (listed) return;
                if (line.Trim() == "Devices:")
                {
                    listing = true;
                    return;
                }
                if (!listing) return;
                Device device = Device.Parse(line, devices.Count);
                if (device != null) devices.Add(device);
                else if (line.TrimStart().StartsWith("transport", StringComparison.Ordinal)) listed = true;
            }
        }

        bool Said(string text)
        {
            lock (gate) return output.Any(line => line.Contains(text));
        }

        // Its last lines, indented, for an error message.
        public string Tail(int count)
        {
            lock (gate)
            {
                if (output.Count == 0) return " it printed nothing.";
                return string.Concat(output.Skip(Math.Max(0, output.Count - count)).Select(line => Environment.NewLine + "  " + line));
            }
        }

        public void Dispose()
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill();
                    process.WaitForExit(5000);
                }
            }
            catch (Win32Exception) { }  // already ending
            catch (InvalidOperationException) { }  // already gone
            process.Dispose();
        }

        // rpc-server outlives a node only when it couldn't join the node's job (or the node was
        // ended in between). Such a leftover holds a port and the build folder.
        public static void StopLeftovers()
        {
            string prefix = Program.Folder.TrimEnd('\\') + "\\";
            foreach (Process process in Process.GetProcessesByName("ggml-rpc-server"))
            {
                using (process)
                {
                    try
                    {
                        if (!process.MainModule.FileName.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) continue;
                        process.Kill();
                        process.WaitForExit(5000);
                    }
                    catch (Win32Exception) { }  // not ours to inspect: another user's, or elevated
                    catch (InvalidOperationException) { }  // exited meanwhile
                }
            }
        }

        // rpc-server binds with SO_REUSEADDR, which on Windows can succeed on a port another
        // program is listening on; an exclusive bind can't.
        static bool PortIsFree(int port)
        {
            using (var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp))
            {
                socket.ExclusiveAddressUse = true;
                try
                {
                    socket.Bind(new IPEndPoint(IPAddress.Loopback, port));
                    return true;
                }
                catch (SocketException)
                {
                    return false;
                }
            }
        }
    }

    // Windows ends rpc-server with the node however the node ends (Ctrl+C, a closed window, a
    // crash, Task Manager): it runs in a job that's killed when the node's handle to it closes.
    static class ChildJob
    {
        static IntPtr job;

        public static void Add(Process process)
        {
            if (job == IntPtr.Zero)
            {
                IntPtr created = NativeMethods.CreateJobObject(IntPtr.Zero, null);
                if (created == IntPtr.Zero) return;
                var limits = new NativeMethods.JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                limits.BasicLimitInformation.LimitFlags = NativeMethods.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                uint size = (uint)Marshal.SizeOf(typeof(NativeMethods.JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
                if (!NativeMethods.SetInformationJobObject(created, NativeMethods.JobObjectExtendedLimitInformation, ref limits, size)) return;
                job = created;
            }
            NativeMethods.AssignProcessToJobObject(job, process.Handle);
        }
    }

    // Accepts the cluster host's connections from the network and pipes each to rpc-server.
    // Connections from any other address are closed unanswered. One session runs at a time: a new
    // connection from the host replaces the old one (the iPad reconnected).
    sealed class Relay
    {
        const int FirstPort = 50052, LastPort = 50061;

        public readonly int Port;
        public volatile int TargetPort;
        readonly Socket listener;
        readonly object gate = new object();
        HashSet<IPAddress> allowed = new HashSet<IPAddress>();
        Session current;
        long bytes;
        volatile bool stopped;

        Relay(Socket listener, int port, int targetPort)
        {
            this.listener = listener;
            Port = port;
            TargetPort = targetPort;
            var thread = new Thread(Accept);
            thread.IsBackground = true;
            thread.Start();
        }

        public static Relay Start(int targetPort)
        {
            for (int port = FirstPort; port <= LastPort; port++)
            {
                var listener = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
                try
                {
                    listener.ExclusiveAddressUse = true;
                    listener.Bind(new IPEndPoint(IPAddress.Any, port));
                    listener.Listen(8);
                    return new Relay(listener, port, targetPort);
                }
                catch (SocketException)
                {
                    listener.Close();
                }
            }
            throw new NodeException("Ports " + FirstPort + " to " + LastPort + " are all taken on this PC, so the iPad has no way in.");
        }

        public long BytesRelayed
        {
            get { return Interlocked.Read(ref bytes); }
        }

        public bool Busy
        {
            get { lock (gate) return current != null && !current.IsClosed; }
        }

        public void SetAllowed(IEnumerable<IPAddress> addresses)
        {
            var set = new HashSet<IPAddress>();
            foreach (IPAddress address in addresses) set.Add(Normalize(address));
            lock (gate) allowed = set;
        }

        public void Stop()
        {
            stopped = true;
            listener.Close();
            Session session;
            lock (gate)
            {
                session = current;
                current = null;
            }
            if (session != null) session.Close();
        }

        internal void Count(int count)
        {
            Interlocked.Add(ref bytes, count);
        }

        void Accept()
        {
            while (!stopped)
            {
                Socket client;
                try
                {
                    client = listener.Accept();
                }
                catch (SocketException)
                {
                    if (stopped) return;
                    Thread.Sleep(100);  // a connection reset before it was accepted
                    continue;
                }
                catch (ObjectDisposedException)
                {
                    return;
                }
                if (!IsAllowed(client))
                {
                    client.Close();
                    continue;
                }
                var session = new Session(this, client);
                Session previous;
                lock (gate)
                {
                    previous = current;
                    current = session;
                }
                if (previous != null) previous.Close();
                var thread = new Thread(session.Run);
                thread.IsBackground = true;
                thread.Start();
            }
        }

        bool IsAllowed(Socket client)
        {
            try
            {
                var remote = (IPEndPoint)client.RemoteEndPoint;
                lock (gate) return allowed.Contains(Normalize(remote.Address));
            }
            catch (SocketException)
            {
                return false;  // gone already
            }
        }

        static IPAddress Normalize(IPAddress address)
        {
            return address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address;
        }
    }

    // One connection from the host, piped to rpc-server both ways until either side ends.
    sealed class Session
    {
        readonly Relay relay;
        readonly Socket client;
        readonly Socket upstream = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        int closed;

        public Session(Relay relay, Socket client)
        {
            this.relay = relay;
            this.client = client;
        }

        public bool IsClosed
        {
            get { return Thread.VolatileRead(ref closed) != 0; }
        }

        public void Run()
        {
            try
            {
                client.NoDelay = true;
                upstream.NoDelay = true;
                upstream.Connect(IPAddress.Loopback, relay.TargetPort);
            }
            catch (SocketException)
            {
                Close();
                return;
            }
            catch (ObjectDisposedException)
            {
                return;  // replaced while connecting
            }
            KeepAlive(client);
            var back = new Thread(delegate() { Pump(upstream, client); });
            back.IsBackground = true;
            back.Start();
            Pump(client, upstream);
        }

        public void Close()
        {
            if (Interlocked.Exchange(ref closed, 1) != 0) return;
            End(client);
            End(upstream);
        }

        void Pump(Socket from, Socket to)
        {
            var buffer = new byte[1 << 20];
            try
            {
                int read;
                while ((read = from.Receive(buffer)) > 0)
                {
                    for (int sent = 0; sent < read; ) sent += to.Send(buffer, sent, read - sent, SocketFlags.None);
                    relay.Count(read);
                }
            }
            catch (SocketException) { }  // reset, or closed by the other direction
            catch (ObjectDisposedException) { }
            Close();
        }

        static void End(Socket socket)
        {
            try
            {
                socket.Shutdown(SocketShutdown.Both);
            }
            catch (SocketException) { }  // not connected
            catch (ObjectDisposedException) { }
            socket.Close();
        }

        // Notices a host that vanished without closing (its Wi-Fi went) within a couple of minutes
        // rather than Windows' two hours, so a dead session doesn't hold rpc-server's memory.
        static void KeepAlive(Socket socket)
        {
            var values = new byte[12];
            BitConverter.GetBytes(1).CopyTo(values, 0);      // on
            BitConverter.GetBytes(30000).CopyTo(values, 4);  // idle time before the first probe, ms
            BitConverter.GetBytes(5000).CopyTo(values, 8);   // time between probes, ms
            try
            {
                socket.IOControl(IOControlCode.KeepAliveValues, values, null);
            }
            catch (SocketException) { }  // the session works without it
            catch (ObjectDisposedException) { }
        }
    }

    // llama.cpp RPC's HELLO, which opens every connection (protocol 8.0.x, little-endian): the
    // command byte 14, a uint64 request size of 24, then 24 bytes of connection capabilities (all
    // zero: plain TCP). The reply is a uint64 size of 28, then major, minor and patch, a padding
    // byte and the server's 24 bytes of capabilities.
    static class RpcHello
    {
        public static void Send(Socket socket)
        {
            var request = new byte[1 + 8 + 24];
            request[0] = 14;
            request[1] = 24;
            for (int sent = 0; sent < request.Length; ) sent += socket.Send(request, sent, request.Length - sent, SocketFlags.None);
        }

        // The server's protocol version, or null when what answered isn't an RPC server.
        public static Version Receive(Socket socket)
        {
            byte[] size = ReceiveExactly(socket, 8);
            if (size == null || BitConverter.ToUInt64(size, 0) != 28) return null;
            byte[] reply = ReceiveExactly(socket, 28);
            return reply == null ? null : new Version(reply[0], reply[1], reply[2]);
        }

        // Asks the rpc-server on this PC's port directly.
        public static Version Ask(int port, int timeoutMilliseconds)
        {
            try
            {
                using (Socket socket = Tcp.Connect(IPAddress.Loopback, port, timeoutMilliseconds))
                {
                    Send(socket);
                    return Receive(socket);
                }
            }
            catch (SocketException)
            {
                return null;
            }
            catch (TimeoutException)
            {
                return null;
            }
        }

        static byte[] ReceiveExactly(Socket socket, int count)
        {
            var buffer = new byte[count];
            for (int have = 0; have < count; )
            {
                int read = socket.Receive(buffer, have, count - have, SocketFlags.None);
                if (read == 0) return null;
                have += read;
            }
            return buffer;
        }
    }

    static class Tcp
    {
        // A connected socket whose connect, sends and receives give up after the timeout.
        public static Socket Connect(IPAddress address, int port, int timeoutMilliseconds)
        {
            var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            try
            {
                IAsyncResult pending = socket.BeginConnect(address, port, null, null);
                if (!pending.AsyncWaitHandle.WaitOne(timeoutMilliseconds)) throw new TimeoutException("No answer from " + address + ":" + port + ".");
                socket.EndConnect(pending);
                socket.NoDelay = true;
                socket.ReceiveTimeout = timeoutMilliseconds;
                socket.SendTimeout = timeoutMilliseconds;
                return socket;
            }
            catch
            {
                socket.Close();
                throw;
            }
        }
    }

    // An answer from the host: its HTTP status (0 when it couldn't be reached) and JSON body.
    sealed class Reply
    {
        public int Status;
        public double Milliseconds;
        public Dictionary<string, object> Body = new Dictionary<string, object>();

        public string Text(string key)
        {
            object value;
            string text = Body.TryGetValue(key, out value) ? value as string : null;
            return string.IsNullOrEmpty(text) ? null : text;
        }

        // JavaScriptSerializer gives numbers as int, long, decimal or double.
        public double Number(string key, double fallback)
        {
            object value;
            if (!Body.TryGetValue(key, out value) || value == null) return fallback;
            try
            {
                return Convert.ToDouble(value, CultureInfo.InvariantCulture);
            }
            catch (FormatException)
            {
                return fallback;
            }
            catch (InvalidCastException)
            {
                return fallback;
            }
        }

        public object[] List(string key)
        {
            object value;
            return Body.TryGetValue(key, out value) && value is object[] ? (object[])value : new object[0];
        }
    }

    // The cluster's HTTP API on the iPad (join, heartbeat, leave), straight over the LAN.
    sealed class HostClient
    {
        readonly Uri root;

        public HostClient(string host)
        {
            string address = host.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ? host.Substring(7) : host;
            if (!Uri.TryCreate("http://" + address.TrimEnd('/'), UriKind.Absolute, out root))
                throw new NodeException("\"" + host + "\" isn't an address OMNIA Node can use. Run the command the iPad shows.");
        }

        // The host's own addresses, the first allowed through the relay.
        public IPAddress[] Addresses()
        {
            IPAddress address;
            if (IPAddress.TryParse(root.DnsSafeHost, out address)) return new[] { address };
            try
            {
                return Dns.GetHostAddresses(root.DnsSafeHost);
            }
            catch (SocketException)
            {
                return new IPAddress[0];  // the join reply lists them
            }
        }

        public Reply Post(string path, Dictionary<string, object> body, int timeoutMilliseconds)
        {
            var reply = new Reply();
            byte[] data = new UTF8Encoding(false).GetBytes(Json.Write(body));
            Stopwatch clock = Stopwatch.StartNew();
            HttpWebResponse response;
            try
            {
                var request = (HttpWebRequest)WebRequest.Create(new Uri(root, path));
                request.Method = "POST";
                request.ContentType = "application/json";
                request.ContentLength = data.Length;
                request.Proxy = null;  // the iPad is on this network, never behind a proxy
                request.KeepAlive = false;
                request.Timeout = timeoutMilliseconds;
                request.ReadWriteTimeout = timeoutMilliseconds;
                using (Stream stream = request.GetRequestStream()) stream.Write(data, 0, data.Length);
                response = (HttpWebResponse)request.GetResponse();
            }
            catch (WebException e)
            {
                response = e.Response as HttpWebResponse;  // an error status still has a body
            }
            catch (IOException)
            {
                response = null;
            }
            if (response == null)
            {
                reply.Milliseconds = clock.Elapsed.TotalMilliseconds;
                return reply;
            }
            using (response)
            {
                reply.Status = (int)response.StatusCode;
                try
                {
                    using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                        reply.Body = Json.ReadObject(reader.ReadToEnd()) ?? reply.Body;
                }
                catch (IOException) { }  // the status alone will do
                catch (WebException) { }
            }
            reply.Milliseconds = clock.Elapsed.TotalMilliseconds;
            return reply;
        }
    }

    static class Json
    {
        public static string Write(object value)
        {
            return new JavaScriptSerializer().Serialize(value);
        }

        // An object, or null when the text isn't a JSON object.
        public static Dictionary<string, object> ReadObject(string text)
        {
            try
            {
                return new JavaScriptSerializer().DeserializeObject(text) as Dictionary<string, object>;
            }
            catch (ArgumentException)
            {
                return null;
            }
            catch (InvalidOperationException)
            {
                return null;
            }
        }
    }

    // llama.cpp's official Windows builds of the pinned release, checked against their SHA-256.
    static class Downloader
    {
        const string Release = "https://github.com/ggml-org/llama.cpp/releases/download/" + Program.LlamaBuild + "/";
        const string CompleteMarker = ".omnia-complete";

        sealed class Asset
        {
            public readonly string Name, Sha256;
            public readonly double Megabytes;

            public Asset(string name, string sha256, double megabytes)
            {
                Name = name;
                Sha256 = sha256;
                Megabytes = megabytes;
            }
        }

        static Asset[] AssetsFor(string backend)
        {
            if (backend == "cuda")
                return new[] {
                    new Asset("llama-b11960-bin-win-cuda-12.4-x64.zip", "8d9d819261de10cc2f03921b8b79c779c5c458e21edb60c170ee30a7d462d684", 279.8),
                    new Asset("cudart-llama-bin-win-cuda-12.4-x64.zip", "8c79a9b226de4b3cacfd1f83d24f962d0773be79f1e7b75c6af4ded7e32ae1d6", 391.4)
                };
            if (backend == "vulkan")
                return new[] { new Asset("llama-b11960-bin-win-vulkan-x64.zip", "bac6914b5e83523eb008c6789eaa12669f93fbc196c3b9e8237b6672323b33e9", 37.3) };
            if (backend == "cpu")
                return new[] { new Asset("llama-b11960-bin-win-cpu-x64.zip", "73f962f82850d244db47eaacb9d913637027b82399124324298576d58c5f4287", 24.4) };
            throw new NodeException("There's no llama.cpp build for the backend \"" + backend + "\".");
        }

        static string Label(string backend)
        {
            if (backend == "cuda") return "NVIDIA GPUs";
            if (backend == "vulkan") return "Vulkan GPUs";
            return "CPUs";
        }

        // The folder holding this backend's build, downloaded and unpacked first if needed.
        public static string Prepare(string backend)
        {
            Asset[] assets = AssetsFor(backend);
            string target = Path.Combine(Program.Folder, "llama-" + Program.LlamaBuild + "-" + backend);
            string marker = Path.Combine(target, CompleteMarker);
            string manifest = string.Join("\n", assets.Select(a => a.Name + " " + a.Sha256));
            if (File.Exists(marker) && File.ReadAllText(marker) == manifest) return target;

            double megabytes = assets.Sum(a => a.Megabytes);
            Ui.Line("Getting llama.cpp " + Program.LlamaBuild + " for " + Label(backend) + " (" + megabytes.ToString("0", CultureInfo.InvariantCulture) + " MB, first run only)...");
            try
            {
                string downloads = Path.Combine(Program.Folder, "downloads");
                Directory.CreateDirectory(downloads);
                var zips = new List<string>();
                for (int i = 0; i < assets.Length; i++)
                    zips.Add(Fetch(assets[i], downloads, assets.Length > 1 ? "Downloading " + (i + 1) + " of " + assets.Length : "Downloading"));

                // Unpacked beside the target and renamed once complete, so a run that stops halfway
                // never leaves a build that looks usable.
                Ui.Status("Unpacking...");
                string staging = target + ".unpacking";
                if (Directory.Exists(staging)) Directory.Delete(staging, true);
                foreach (string zip in zips) Unzip(zip, staging);
                File.WriteAllText(Path.Combine(staging, CompleteMarker), manifest);
                if (Directory.Exists(target)) Directory.Delete(target, true);
                Directory.Move(staging, target);
                foreach (string zip in zips) File.Delete(zip);
            }
            catch (IOException e)
            {
                throw new NodeException("Couldn't set up llama.cpp in " + Program.Folder + ": " + e.Message);
            }
            catch (UnauthorizedAccessException e)
            {
                throw new NodeException("Couldn't set up llama.cpp in " + Program.Folder + ": " + e.Message);
            }
            finally
            {
                Ui.ClearStatus();
            }
            return target;
        }

        // One zip, resumed after a dropped connection. A damaged download is fetched once more from
        // scratch before giving up.
        static string Fetch(Asset asset, string folder, string what)
        {
            string zip = Path.Combine(folder, asset.Name);
            if (File.Exists(zip) && Sha256Of(zip) == asset.Sha256) return zip;  // from a run that stopped before unpacking
            string part = zip + ".part";
            for (int round = 1; ; round++)
            {
                Download(asset.Name, part, what);
                Ui.Status("Checking " + asset.Name + "...");
                if (Sha256Of(part) == asset.Sha256) break;
                File.Delete(part);
                if (round == 2)
                    throw new NodeException("The download of " + asset.Name + " didn't match its SHA-256 twice, so it wasn't used. Check the network, then run the command again.");
            }
            if (File.Exists(zip)) File.Delete(zip);
            File.Move(part, zip);
            Ui.Line("Verified " + asset.Name + " (SHA-256 matches)");
            return zip;
        }

        static void Download(string name, string part, string what)
        {
            for (int attempt = 1; ; attempt++)
            {
                try
                {
                    DownloadOnce(Release + name, part, what);
                    return;
                }
                catch (WebException e)
                {
                    if (attempt == 5 || !Retryable(e)) throw new NodeException("Couldn't download " + name + " from GitHub: " + e.Message);
                }
                catch (IOException e)
                {
                    if (attempt == 5) throw new NodeException("Couldn't download " + name + ": " + e.Message);
                }
                Ui.Status("The connection dropped. Resuming...");
                Program.Pause(3000);
            }
        }

        // A missing file or a refusal won't change by asking again; anything else might.
        static bool Retryable(WebException e)
        {
            var response = e.Response as HttpWebResponse;
            return response == null || (int)response.StatusCode >= 500 || (int)response.StatusCode == 429;
        }

        static void DownloadOnce(string url, string part, string what)
        {
            long have = File.Exists(part) ? new FileInfo(part).Length : 0;
            var request = (HttpWebRequest)WebRequest.Create(url);
            request.UserAgent = "OMNIA-Node";
            request.Timeout = 30000;
            request.ReadWriteTimeout = 30000;
            if (have > 0) request.AddRange(have);
            HttpWebResponse response;
            try
            {
                response = (HttpWebResponse)request.GetResponse();
            }
            catch (WebException e)
            {
                var refused = e.Response as HttpWebResponse;
                if (have == 0 || refused == null || (int)refused.StatusCode != 416) throw;
                refused.Close();
                return;  // nothing left to fetch; the checksum decides
            }
            using (response)
            using (Stream input = response.GetResponseStream())
            {
                bool resumed = have > 0 && response.StatusCode == HttpStatusCode.PartialContent;
                if (!resumed) have = 0;
                long total = response.ContentLength >= 0 ? have + response.ContentLength : -1;
                using (var output = new FileStream(part, resumed ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16))
                {
                    var buffer = new byte[1 << 20];
                    long start = have;
                    Stopwatch clock = Stopwatch.StartNew();
                    TimeSpan shown = TimeSpan.Zero;
                    int read;
                    while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        if (Program.Stop.IsCancellationRequested) throw new OperationCanceledException();
                        output.Write(buffer, 0, read);
                        have += read;
                        if (Ui.IsConsole && clock.Elapsed - shown >= TimeSpan.FromMilliseconds(250))
                        {
                            shown = clock.Elapsed;
                            Ui.Status(Progress(what, have, total, (have - start) / shown.TotalSeconds));
                        }
                    }
                }
                if (total >= 0 && have < total) throw new IOException("The connection closed early.");
            }
        }

        static string Progress(string what, long have, long total, double bytesPerSecond)
        {
            string done = total > 0
                ? (100.0 * have / total).ToString("0", CultureInfo.InvariantCulture) + "% of " + Megabytes(total)
                : Megabytes(have);
            return what + ": " + done + ", " + (bytesPerSecond / 1e6).ToString("0.0", CultureInfo.InvariantCulture) + " MB/s";
        }

        static string Megabytes(long bytes)
        {
            return (bytes / 1e6).ToString("0.0", CultureInfo.InvariantCulture) + " MB";
        }

        static string Sha256Of(string path)
        {
            using (var sha = new SHA256CryptoServiceProvider())
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20))
                return string.Concat(sha.ComputeHash(stream).Select(b => b.ToString("x2", CultureInfo.InvariantCulture)));
        }

        static void Unzip(string zip, string folder)
        {
            Directory.CreateDirectory(folder);
            string root = Path.GetFullPath(folder).TrimEnd('\\') + "\\";
            using (ZipArchive archive = ZipFile.OpenRead(zip))
            {
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    string path = Path.GetFullPath(Path.Combine(root, entry.FullName));
                    if (!path.StartsWith(root, StringComparison.OrdinalIgnoreCase)) continue;  // never outside the folder
                    if (entry.Name.Length == 0)
                    {
                        Directory.CreateDirectory(path);  // a folder entry
                        continue;
                    }
                    Directory.CreateDirectory(Path.GetDirectoryName(path));
                    entry.ExtractToFile(path, true);
                }
            }
        }
    }

    // Free GPU memory for heartbeats: rpc-server reports it only when it starts.
    static class NvidiaSmi
    {
        // {index, memoryFree} per CUDA device. nvidia-smi's GPUs are matched by name, since its
        // order can differ from CUDA's on a PC with different GPUs, and by order otherwise.
        public static List<object> FreeMemory(List<Device> devices)
        {
            List<KeyValuePair<string, long>> gpus = Query();
            if (gpus == null) return null;
            var used = new bool[gpus.Count];
            var result = new List<object>();
            for (int i = 0; i < devices.Count; i++)
            {
                Device device = devices[i];
                if (!device.Name.StartsWith("CUDA", StringComparison.Ordinal)) continue;
                int match = -1;
                for (int j = 0; j < gpus.Count && match < 0; j++)
                    if (!used[j] && gpus[j].Key == device.Description) match = j;
                if (match < 0 && i < gpus.Count && !used[i]) match = i;
                if (match < 0) continue;
                used[match] = true;
                device.MemoryFree = gpus[match].Value * Program.Mebibyte;
                var entry = new Dictionary<string, object>();
                entry["index"] = device.Index;
                entry["memoryFree"] = device.MemoryFree;
                result.Add(entry);
            }
            return result;
        }

        // (name, free MiB) per GPU, or null when nvidia-smi isn't there or doesn't answer.
        static List<KeyValuePair<string, long>> Query()
        {
            string exe = Path.Combine(Environment.SystemDirectory, "nvidia-smi.exe");
            if (!File.Exists(exe))
                exe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"NVIDIA Corporation\NVSMI\nvidia-smi.exe");
            if (!File.Exists(exe)) return null;
            var info = new ProcessStartInfo(exe, "--query-gpu=name,memory.free --format=csv,noheader,nounits");
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.RedirectStandardOutput = true;
            try
            {
                using (Process process = Process.Start(info))
                {
                    Task<string> output = process.StandardOutput.ReadToEndAsync();
                    if (!process.WaitForExit(5000))
                    {
                        process.Kill();
                        return null;
                    }
                    if (!output.Wait(1000) || process.ExitCode != 0) return null;
                    var gpus = new List<KeyValuePair<string, long>>();
                    foreach (string line in output.Result.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
                    {
                        int comma = line.LastIndexOf(',');
                        long free;
                        if (comma > 0 && long.TryParse(line.Substring(comma + 1).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out free))
                            gpus.Add(new KeyValuePair<string, long>(line.Substring(0, comma).Trim(), free));
                    }
                    return gpus;
                }
            }
            catch (Win32Exception)
            {
                return null;
            }
            catch (InvalidOperationException)
            {
                return null;
            }
        }
    }

    static class Machine
    {
        // "Windows 11 Pro 10.0.26100", from the registry: .NET Framework reports Windows 8's
        // version to programs without a compatibility manifest.
        public static string Platform()
        {
            using (RegistryKey key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
            {
                if (key == null) return "Windows";
                string product = key.GetValue("ProductName") as string ?? "Windows";
                string build = key.GetValue("CurrentBuildNumber") as string ?? "";
                int number;
                // Windows 11 kept Windows 10's product name.
                if (int.TryParse(build, NumberStyles.Integer, CultureInfo.InvariantCulture, out number) && number >= 22000)
                    product = product.Replace("Windows 10", "Windows 11");
                object major = key.GetValue("CurrentMajorVersionNumber"), minor = key.GetValue("CurrentMinorVersionNumber");
                if (major == null || minor == null || build.Length == 0) return product;
                return product + " " + major + "." + minor + "." + build;
            }
        }

        public static long TotalMemory()
        {
            var status = new NativeMethods.MEMORYSTATUSEX();
            status.dwLength = (uint)Marshal.SizeOf(typeof(NativeMethods.MEMORYSTATUSEX));
            return NativeMethods.GlobalMemoryStatusEx(ref status) ? (long)status.ullTotalPhys : 0;
        }
    }

    // OMNIA_NODE_SELFTEST=1, for CI (no GPU, no iPad): the CPU build through the same download,
    // start and relay code as a real node, with loopback standing in for the iPad.
    static class SelfTest
    {
        static int passed, failed;

        public static int Run()
        {
            Ui.Line("OMNIA Node self-test: llama.cpp " + Program.LlamaBuild + ", CPU build");
            RpcServerProcess.StopLeftovers();
            string build = Downloader.Prepare("cpu");
            using (RpcServerProcess rpc = RpcServerProcess.Start(build))
            {
                List<Device> devices = rpc.Devices;
                Device cpu = devices.FirstOrDefault(d => d.Name.StartsWith("CPU", StringComparison.Ordinal));
                Check(cpu != null, "rpc-server lists a CPU device", cpu != null
                    ? cpu.Name + ": " + cpu.Description + ", " + cpu.MemoryTotal / Program.Mebibyte + " MiB"
                    : "it listed " + (devices.Count == 0 ? "nothing" : string.Join(", ", devices.Select(d => d.Name))));
                Relay relay = Relay.Start(rpc.Port);
                relay.SetAllowed(new[] { IPAddress.Loopback });
                Ui.Line("rpc-server on 127.0.0.1:" + rpc.Port + ", relay on port " + relay.Port);
                try
                {
                    CheckHostConnections(relay);
                    CheckOtherAddress(relay);
                }
                finally
                {
                    relay.Stop();
                }
            }
            Ui.Line(failed == 0
                ? "Self-test passed (" + passed + " checks)."
                : "Self-test failed: " + failed + " of " + (passed + failed) + " checks.");
            return failed == 0 ? 0 : 1;
        }

        // The host's connections reach rpc-server, and a new one replaces the old (the iPad
        // reconnected).
        static void CheckHostConnections(Relay relay)
        {
            try
            {
                using (Socket first = Tcp.Connect(IPAddress.Loopback, relay.Port, 5000))
                {
                    RpcHello.Send(first);
                    Version version = RpcHello.Receive(first);
                    Check(version != null && version.Major == 8, "the relay passes the host's HELLO to rpc-server", version != null ? "protocol " + version : "no answer");
                    using (Socket second = Tcp.Connect(IPAddress.Loopback, relay.Port, 5000))
                    {
                        string detail;
                        Check(EndsUnanswered(first, out detail), "a new connection from the host ends the old one", detail);
                        RpcHello.Send(second);
                        Version again = RpcHello.Receive(second);
                        Check(again != null && again.Major == 8, "the new connection reaches rpc-server", again != null ? "protocol " + again : "no answer");
                    }
                }
            }
            catch (SocketException e)
            {
                Check(false, "connections from the host", e.Message);
            }
            catch (TimeoutException e)
            {
                Check(false, "connections from the host", e.Message);
            }
        }

        // Anyone else on the network is turned away without an answer.
        static void CheckOtherAddress(Relay relay)
        {
            IPAddress address = NetworkAddress();
            if (address == null)
            {
                Ui.Line("SKIP  connections from other addresses: this machine has no address besides loopback");
                return;
            }
            string what = "the relay closes connections from " + address + " unanswered";
            try
            {
                using (Socket socket = Tcp.Connect(address, relay.Port, 5000))
                {
                    try
                    {
                        RpcHello.Send(socket);
                    }
                    catch (SocketException) { }  // closed already, which is the point
                    string detail;
                    Check(EndsUnanswered(socket, out detail), what, detail);
                }
            }
            catch (SocketException e)
            {
                Check(false, what, e.Message);
            }
            catch (TimeoutException e)
            {
                Check(false, what, e.Message);
            }
        }

        // True when the other side closes or resets the connection within 5 s without sending
        // anything.
        static bool EndsUnanswered(Socket socket, out string detail)
        {
            try
            {
                socket.ReceiveTimeout = 5000;
                int read = socket.Receive(new byte[64]);
                detail = read == 0 ? "closed" : "answered with " + read + " bytes";
                return read == 0;
            }
            catch (SocketException e)
            {
                detail = e.SocketErrorCode == SocketError.TimedOut ? "still open after 5 s" : "reset";
                return e.SocketErrorCode != SocketError.TimedOut;
            }
        }

        static IPAddress NetworkAddress()
        {
            foreach (NetworkInterface adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (adapter.OperationalStatus != OperationalStatus.Up || adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                foreach (UnicastIPAddressInformation unicast in adapter.GetIPProperties().UnicastAddresses)
                {
                    if (unicast.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(unicast.Address)) return unicast.Address;
                }
            }
            return null;
        }

        static void Check(bool ok, string what, string detail)
        {
            if (ok) passed++;
            else failed++;
            Ui.Line((ok ? "PASS  " : "FAIL  ") + what + (string.IsNullOrEmpty(detail) ? "" : " (" + detail + ")"));
        }
    }

    // Console output: plain lines, plus one status line that rewrites itself in a console window.
    // Redirected output (a CI log) gets each new status once, as a line of its own.
    static class Ui
    {
        static readonly object Gate = new object();
        static bool console;
        static Encoding savedEncoding;
        static string savedTitle;
        static string status = "";

        public static bool IsConsole
        {
            get { return console; }
        }

        // Cluster and GPU names can be in any script, so the console gets UTF-8. It and the window
        // title go back to what they were on exit, for the shell that ran the node.
        public static void Start()
        {
            try
            {
                console = !Console.IsOutputRedirected;
                if (!console) return;
                savedEncoding = Console.OutputEncoding;
                Console.OutputEncoding = new UTF8Encoding(false);
                savedTitle = Console.Title;
                Console.Title = "OMNIA Node";
            }
            catch (IOException) { }  // a console that can't change: names may show as "?"
        }

        public static void Finish()
        {
            ClearStatus();
            try
            {
                if (savedEncoding != null) Console.OutputEncoding = savedEncoding;
                if (savedTitle != null) Console.Title = savedTitle;
            }
            catch (IOException) { }
        }

        public static void Line(string text)
        {
            lock (Gate)
            {
                if (console && status.Length > 0) Console.Write("\r" + new string(' ', status.Length) + "\r");
                Console.WriteLine(text);
                if (console && status.Length > 0) Console.Write(status);
            }
        }

        public static void Status(string text)
        {
            lock (Gate)
            {
                if (console) text = Fit(text);
                if (text == status) return;
                if (console) Console.Write("\r" + new string(' ', status.Length) + "\r" + text);
                else Console.WriteLine(text);
                status = text;
            }
        }

        public static void ClearStatus()
        {
            lock (Gate)
            {
                if (console && status.Length > 0) Console.Write("\r" + new string(' ', status.Length) + "\r");
                status = "";
            }
        }

        // A window opened just for this command (from the Run dialog, say) closes as soon as the node
        // exits, taking the reason with it. Keep it until the user has read it.
        public static void PauseIfWindowCloses()
        {
            if (!console) return;
            try
            {
                if (Console.IsInputRedirected) return;
                uint attached = NativeMethods.GetConsoleProcessList(new uint[4], 4);
                if (attached == 0 || attached > 2) return;  // a shell (cmd, PowerShell) keeps this window open
                ClearStatus();
                Console.Write("Press Enter to close this window.");
                Console.ReadLine();
            }
            catch (IOException) { }
        }

        // A line wider than the window wraps, and "\r" would then rewrite only its last row.
        static string Fit(string text)
        {
            int width;
            try
            {
                width = Console.WindowWidth;
            }
            catch (IOException)
            {
                return text;
            }
            return width > 4 && text.Length >= width ? text.Substring(0, width - 4) + "..." : text;
        }
    }

    static class NativeMethods
    {
        public const int CtrlClose = 2, CtrlLogoff = 5, CtrlShutdown = 6;
        public const int JobObjectExtendedLimitInformation = 9;
        public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

        public delegate bool ConsoleCtrlHandler(int type);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetConsoleCtrlHandler(ConsoleCtrlHandler handler, bool add);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint GetConsoleProcessList(uint[] processes, uint count);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateJobObject(IntPtr attributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, uint length);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX buffer);

        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct MEMORYSTATUSEX
        {
            public uint dwLength;
            public uint dwMemoryLoad;
            public ulong ullTotalPhys;
            public ulong ullAvailPhys;
            public ulong ullTotalPageFile;
            public ulong ullAvailPageFile;
            public ulong ullTotalVirtual;
            public ulong ullAvailVirtual;
            public ulong ullAvailExtendedVirtual;
        }
    }
}
'@

# Named after its source: a changed program compiles anew, an unchanged one starts at once and
# keeps the firewall permission Windows gave it. Line endings don't count.
$source = $source -replace "`r`n", "`n"
$sha256 = New-Object System.Security.Cryptography.SHA256CryptoServiceProvider
$digest = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($source))
$exe = Join-Path $nodeFolder ('omnia-node-' + (-join ($digest[0..5] | ForEach-Object { $_.ToString('x2') })) + '.exe')

if (-not (Test-Path -LiteralPath $exe)) {
    Write-Host 'Preparing OMNIA Node...'
    # Compiled under a temporary name, so a compile cut short never leaves a broken program.
    $partial = Join-Path $nodeFolder ('omnia-node-' + [guid]::NewGuid().ToString('N') + '.exe')
    try {
        New-Item -ItemType Directory -Force -Path $nodeFolder | Out-Null
        $compile = @{
            TypeDefinition = $source
            Language = 'CSharp'
            OutputAssembly = $partial
            OutputType = 'ConsoleApplication'
            ReferencedAssemblies = 'System', 'System.Core', 'System.Web.Extensions', 'System.IO.Compression', 'System.IO.Compression.FileSystem'
            IgnoreWarnings = $true
        }
        Add-Type @compile
        Move-Item -LiteralPath $partial -Destination $exe
    } catch {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        Write-Host "OMNIA Node couldn't be prepared on this PC: $($_.Exception.Message)"
        exit 1
    }
}

# Each value goes over in base64: Windows PowerShell passes quotes and empty strings to programs
# badly, and a cluster name can hold anything.
function ConvertTo-NodeArgument([string]$Name, [string]$Value) {
    '--' + $Name + '=' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Value))
}
$arguments = @(
    (ConvertTo-NodeArgument 'host' $omniaHost)
    (ConvertTo-NodeArgument 'token' $omniaToken)
    (ConvertTo-NodeArgument 'cluster' $omniaCluster)
    (ConvertTo-NodeArgument 'backend' $backend)
)
if ($publicNetwork) { $arguments += '--public-network' }
if ($selfTest) { $arguments += '--self-test' }

# The program's own output must never turn into a terminating error here.
$ErrorActionPreference = 'Continue'
& $exe @arguments
if ($null -eq $LASTEXITCODE) { exit 1 }
exit $LASTEXITCODE
