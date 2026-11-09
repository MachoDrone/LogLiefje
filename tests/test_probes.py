import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


MAIN = Path(__file__).resolve().parents[1] / 'LogLiefje.sh'
WALLET_A = 'A' * 43
WALLET_B = 'B' * 43
SERVER = 'node.k8s.prd.nos.ci'


def probe_module():
    # Isolate the shipped single-file probe from the host collector's other entry points.
    source = Path(os.environ.get('LL_TEST_PROBE_SOURCE', MAIN)).read_text()
    block = source.split("# BEGIN LOGLIEFJE CONTAINER NETWORK REPORT\n", 1)[1]
    code = block.split("<<'LOGLIEFJE_NETWORK_PY'", 1)[1].split('\n', 1)[1].split('\nLOGLIEFJE_NETWORK_PY')[0]
    namespace = {}
    exec(compile(code.rsplit('\nreport()', 1)[0], str(MAIN) + ':network', 'exec'), namespace)
    return namespace


def route(wallet, alias='nosana-node', server=SERVER):
    return (f'serverAddr = "{server}"\nserverPort = 7000\n'
            f'[[proxies]]\nname = "API-{wallet}"\ntype = "http"\n'
            f'localIp = "{alias}"\nlocalPort = 8123\ncustomDomains = ["{wallet}.{server}"]\n')


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.mod = probe_module()
        self.node = self.mod['Node']('b'*64,'nosana-node','docker.io/nosana/nosana-node:1.1.86','Up 19 hours')
        self.proxy = self.mod['Node']('c'*64,'frpc-api-'+WALLET_A,'nosana/frpc:v1.0.45','running')

    def test_route_requires_matching_domain_and_fields_from_one_proxy(self):
        parse = self.mod['config_route']
        good = route(WALLET_A)
        self.assertEqual(parse(good,WALLET_A)['port'], 8123)
        for wrong in (good.replace(WALLET_A+'.',WALLET_B+'.'),
                      good.replace('API-'+WALLET_A,'API-'+WALLET_B),
                      good.replace('8123','65536'),
                      good.replace('localPort','[[proxies]]\nlocalPort'),
                      good.replace('localPort','[unrelated]\nlocalPort'),
                      good.replace(SERVER,'untrusted.example'),
                      good.replace('nosana-node','bad;name')):
            self.assertIsNone(parse(wrong,WALLET_A))
        self.assertIsNone(parse(good + 'serverAddr = "node.k8s.prd.nos.ci"\n',WALLET_A))

    def test_history_excludes_earlier_process_and_partial_lines(self):
        old = '2026-11-07T08:00:00.000000001Z stdout F '
        new = '2026-11-07T08:00:00.000000002Z stdout F '
        input_log = '\n'.join(old+line for line in route(WALLET_A).splitlines())
        input_log += '\n'+'\n'.join(new+line for line in route(WALLET_B).splitlines())
        input_log += '\n2026-11-07T08:00:00.000000003Z stdout P serverAddr = "unverified.example"'
        config = self.mod['current_log_config'](input_log,new.split()[0])
        self.assertNotIn(WALLET_A,config)
        self.assertIsNotNone(self.mod['config_route'](config,WALLET_B))
        self.assertEqual(self.mod['current_log_config'](input_log,'unknown'), '')
        self.assertEqual(self.mod['current_log_config'](input_log,'1970-01-01T00:00:00Z'), '')

    def test_inventory_filters_lookalikes_and_handles_old_podman_state(self):
        image_is, running = self.mod['image_is'],self.mod['running']
        self.assertTrue(image_is(self.node,'nosana-node'))
        self.assertTrue(image_is(self.node._replace(image='registry.hub.docker.com/nosana/nosana-node:v1.1.86'),'nosana-node'))
        self.assertFalse(image_is(self.node._replace(image='untrusted.example/nosana/nosana-node:latest'),'nosana-node'))
        for state in ['Up 19 hours','Up Less than a second','running']:
            self.assertTrue(running(self.node._replace(state=state)))
        for state in ['Exited (0) 3 hours ago','created','paused','Up 19 hours (Paused)']:
            self.assertFalse(running(self.node._replace(state=state)))

    def test_duplicate_alias_in_same_wrapper_and_shared_network_is_ambiguous(self):
        a = self.node
        b = self.node._replace(id='d'*64,name='nosana-node-two')
        mapping = {self.proxy.id:{'gateway':{}}, b.id:{'gateway':{'Aliases':['nosana-node']}}}
        def networks_for(item):
            return mapping.get(item.id,{})
        node,reason=self.mod['match_node'](networks_for, [a,b], self.proxy, 'nosana-node')
        self.assertIsNone(node)
        self.assertIn('ambiguous',reason)
        mapping[b.id]={'other':{'Aliases':['nosana-node']}}
        self.assertEqual(self.mod['match_node'](networks_for, [a,b], self.proxy, 'nosana-node')[0],a)

    def test_only_node_addresses_on_shared_networks_are_expected(self):
        node = {'left': {'IPAddress': '192.0.2.74', 'GlobalIPv6Address': '2001:db8:0:0::74',
                         'SecondaryIPAddresses': [{'Addr': '192.0.2.75', 'PrefixLength': 24}],
                         'SecondaryIPv6Addresses': [{'Addr': '2001:db8::75', 'PrefixLength': 64}]},
                'right': {'IPAddress': '198.51.100.74'},
                'private': {'IPAddress': '203.0.113.1'}}
        proxy = {'left': {'IPAddress': '192.0.2.33'}, 'right': {}}
        self.assertEqual(self.mod['shared_node_ips'](proxy, node),
                         {'192.0.2.74', '192.0.2.75', '198.51.100.74', '2001:db8::74', '2001:db8::75'})
        self.assertEqual(self.mod['shared_node_ips']({'other': {}}, node), set())

    def test_dns_only_answers_are_distinct_from_resolver_and_effective_lookup(self):
        header = 'Server:\t\t192.0.2.53\nAddress:\t192.0.2.53:53\n\n'
        def result(kind, rc, reply, expected=frozenset({'192.0.2.74', '2001:db8::74'})):
            def capture(args, **kwargs):
                self.assertEqual(args, ['exec', self.proxy.id, 'timeout', '4', 'nslookup',
                                        '-type=' + kind, 'node-on-bridge-2.'])
                return rc, reply
            with patch.dict(self.mod, capture=capture):
                return self.mod['direct_dns'](['exec', self.proxy.id], 'node-on-bridge-2', kind, expected)

        single = header + 'Name:\tnode-on-bridge-2\nAddress: 192.0.2.74\n'
        self.assertEqual(result('A', 0, single), '192.0.2.74 (matches node)')
        self.assertEqual(result('A', 0, single, set()), '192.0.2.74 (node IP comparison unavailable)')
        mixed = single + 'Name:\tnode-on-bridge-2\nAddress: 192.0.2.90\n'
        self.assertIn('includes an address outside the matched node', result('A', 0, mixed))
        self.assertEqual(result('AAAA', 0, header + 'Name: node-on-bridge-2\nAddress: 2001:db8::74\n'),
                         '2001:db8::74 (matches node)')
        self.assertEqual(result('AAAA', 0, header), 'no AAAA address records')
        self.assertEqual(result('A', 1, header + "** server can't find node-on-bridge-2: NXDOMAIN\n"), 'NXDOMAIN')
        self.assertEqual(result('A', 1, header + '** server returned: SERVFAIL\n'), 'SERVFAIL')
        self.assertIn('tool unavailable', result('A', 127, ''))
        self.assertIn('timeout', result('A', 124, ''))
        self.assertEqual(result('A', 1, ';; connection timed out; no servers could be reached'),
                         'unavailable (no DNS server responded)')
        self.assertIn('unavailable', result('A', 1, 'BusyBox nslookup: invalid option'))

    def test_hosts_lookup_outputs_only_addresses_for_the_exact_alias(self):
        source = ('127.0.0.1 localhost\n203.0.113.45 private-name # ALIAS2\n'
                  '192.0.2.32 alias2-old\n192.0.2.74 primary ALIAS2 # sensitive comment\n'
                  '2001:db8::74 alias2\n')
        def capture(args, **kwargs):
            self.assertEqual(args[-1], '/etc/hosts')
            proc = subprocess.run(args[:-1], input=source, text=True, capture_output=True, check=True)
            return proc.returncode, proc.stdout
        with patch.dict(self.mod, capture=capture):
            self.assertEqual(self.mod['hosts_entry']([], 'alias2'), '192.0.2.74, 2001:db8::74')
            self.assertEqual(self.mod['hosts_entry']([], 'alias-missing'), 'no entry')

    def test_collects_matching_nodes_from_two_wrappers_and_keeps_failed_dns(self):
        outer_a=self.node._replace(id='1'*64,name='podman-gpu0',image='nosana/podman:1.1.2',state='running')
        outer_b=outer_a._replace(id='2'*64,name='podman-gpu1')
        outer_off=outer_a._replace(id='3'*64,name='podman-old',state='exited')
        node_b=self.node._replace(id='d'*64)
        proxy_b=self.proxy._replace(id='e'*64,name='frpc-api-'+WALLET_B)
        actual_routes={}
        def inventory(cmd):
            if cmd==['docker']:
                return [outer_a,outer_b,outer_off]
            return [self.node,self.proxy] if cmd[2]==outer_a.id else [node_b,proxy_b]
        def capture(cmd,**kwargs):
            outer_id=cmd[2]
            wallet=WALLET_A if outer_id==outer_a.id else WALLET_B
            ip='192.0.2.74' if outer_id==outer_a.id else '198.51.100.62'
            if 'inspect' in cmd:
                network='gpu-'+outer_id[:1]
                return 0,json.dumps({network:{'IPAddress':ip}})
            if 'nslookup' in cmd:
                answer = 'Name: nosana-node\nAddress: '+ip+'\n' if '-type=A' in cmd else ''
                return 0,'Server: 192.0.2.53\nAddress: 192.0.2.53:53\n\n'+answer
            if cmd[-1]=='/etc/hosts':
                return 0,''
            if 'awk' in cmd:
                generated=route(wallet)+'auth.token = "SECRET"\n'
                completed=subprocess.run(['awk',cmd[cmd.index('awk')+1]],input=generated,text=True,
                                         capture_output=True,check=True)
                self.assertNotIn('SECRET',completed.stdout)
                return 0,completed.stdout
            if 'getent' in cmd:
                return (2,'') if cmd[-1]=='nosana-node' else (0,'192.0.2.12 node.example\n')
            if 'curl' in cmd:
                return 0,json.dumps(wallet)+'\n200'
            if 'cat' in cmd:
                return 0,'nameserver 192.0.2.53\n'
            if 'node' in cmd:
                target=json.loads(cmd[-1])
                actual_routes[outer_id]=(cmd[cmd.index('node')-1],target.get('wallet'))
                return 0,'[["loopback /", "HTTP 200, identity matched (pass) [1 ms]"]]'
            self.fail(cmd)
        output=io.StringIO()
        with patch.dict(self.mod,inventory=inventory,capture=capture,read_logs=lambda *args:('','empty')):
            with contextlib.redirect_stdout(output):
                self.mod['report']()
        self.assertEqual(actual_routes,{outer_a.id:(self.node.id,WALLET_A),outer_b.id:(node_b.id,WALLET_B)})
        self.assertEqual(output.getvalue().count('FRPC DNS node alias nosana-node: failed (exit 2)'),2)
        self.assertEqual(output.getvalue().count('FRPC to node /: HTTP 200, identity matched (pass)'),2)
        for ip in ('192.0.2.74','198.51.100.62'):
            self.assertIn('FRPC direct DNS A nosana-node: '+ip+' (matches node)',output.getvalue())
        self.assertIn('wrapper exited',output.getvalue())

    def test_stopped_missing_support_independent_node_dns(self):
        with patch.dict(self.mod,capture=lambda *args,**kwargs:(127,'')):
            results=self.mod['frp_checks']([],self.proxy,{'alias':'nosana-node','server':SERVER,'wallet':WALLET_A,'port':8123},self.node)
            self.assertTrue(any('no active shared-network IP verified' in row for row in results))
            self.assertEqual(sum('exit 127' in row for row in results),7)
            self.assertIn('container exited',self.mod['node_checks']([],self.node._replace(state='exited'))[0])
        calls=[]
        def node_only(cmd,**kwargs):
            calls.append(json.loads(cmd[-1]))
            return 0,'[["DNS Host Manager", "192.0.2.12 [1 ms]"]]'
        with patch.dict(self.mod,capture=node_only):
            results=self.mod['node_checks']([],self.node)
        self.assertEqual(calls,[{'manager':'host-manager.k8s.prd.nos.ci'}])
        self.assertTrue(any('route-specific' in row and 'skipped' in row for row in results))

    def test_stopped_and_missing_frpc_records(self):
        outer=self.node._replace(name='podman',image='nosana/podman:v1.1.2')
        stopped=self.proxy._replace(state='Exited (0) 3 hours ago')
        for found in (True,False):
            executed=[]
            def inventory(cmd):
                return [outer] if cmd==['docker'] else [self.node]+([stopped] if found else [])
            def capture(cmd, **kwargs):
                if 'inspect' in cmd:
                    return 0,'2026-11-07T01:02:03Z'
                if stopped.id in cmd:
                    self.fail('executed inside stopped FRPC')
                executed.append(cmd[cmd.index('node')-1])
                return 0,'[["DNS Host Manager","203.0.113.42 [1 ms]"]]'
            text=io.StringIO()
            with patch.dict(self.mod,inventory=inventory,capture=capture,read_logs=lambda *args:('','empty')):
                with contextlib.redirect_stdout(text):
                    self.mod['report']()
            self.assertEqual(executed,[self.node.id])
            self.assertIn('node DNS Host Manager: 203.0.113.42',text.getvalue())
            self.assertIn('FRPC checks skipped: container Exited' if found else 'No matching FRPC container found',text.getvalue())

    def test_capture_bounds_output_time_and_stderr(self):
        capture=self.mod['capture']
        self.assertEqual(capture([sys.executable,'-c','print("x"*1000000)'],size=120)[0],125)
        self.assertEqual(capture([sys.executable,'-c','import time; time.sleep(3)'],seconds=.05)[0],124)
        reasons=[]
        code="import sys; print('could not resolve host: SECRET', file=sys.stderr); sys.exit(6)"
        self.assertEqual(capture([sys.executable,'-c',code],diagnostics=reasons),(6,''))
        self.assertEqual(reasons,['could not resolve host'])
        host='nosana-node'
        for line in ['curl: (6) Could not resolve host: nosana-node',
                     'getent: nosana-node: Temporary failure in name resolution']:
            self.assertEqual(self.mod['safe_tool_error'](line.encode(),[host]),line)
        self.assertNotIn('PRIVATE',self.mod['safe_tool_error'](
            b'getent: Temporary failure in name resolution token=PRIVATE',[host]))

    @unittest.skipUnless(shutil.which('node'),'Node.js required to exercise the shipped node-side probe')
    def test_actual_node_probe_with_in_memory_http_and_dns_transports(self):
        # HTTP requests and name lookups are deterministic in-memory fixtures; no external network.
        preload=r"""
const dns=require('dns'), http=require('http'), https=require('https'), E=require('events');
dns.promises.lookup=async host=>{
  if(host.startsWith('node.') && process.env.FAKE_HEALTHY!=='yes')
    throw Object.assign(new Error('fail'),{code:'ENOTFOUND',syscall:'getaddrinfo',hostname:host});
  return [{address:'203.0.113.12'}];
};
function get(url,cb){
  const req=new E(); req.destroy=()=>{};
  setImmediate(()=>{
    const res=new E(); const publicFail=url.startsWith('https') && process.env.FAKE_HEALTHY!=='yes';
    res.statusCode=publicFail?503:200; cb(res);
    const info=url.endsWith('/node/info');
    const wrong=process.env.FAKE_WRONG==='yes';
    const root=process.env.FAKE_WRONG==='object'?{address:process.env.FAKE_WALLET}:process.env.FAKE_WALLET;
    const value=info ? (publicFail?'x'.repeat(66000):'{"info":{"version":"test"}}')
                     : JSON.stringify(wrong?'wrong':root);
    res.emit('data',Buffer.from(value)); res.emit('end');
  });
  return req;
}
http.get=get;https.get=get;
"""
        cfg={'server':SERVER,'wallet':WALLET_A,'port':8123,'manager':self.mod['HOST_MANAGER']}
        with tempfile.TemporaryDirectory() as tmp:
            mock=Path(tmp)/'preload.cjs'
            mock.write_text(preload)
            def run(wrong,healthy='no'):
                proc=subprocess.run(['node','--require',str(mock),'-e',self.mod['NODE_CHECKS'],json.dumps(cfg)],
                                    env=dict(os.environ,FAKE_WALLET=WALLET_A,FAKE_WRONG=wrong,FAKE_HEALTHY=healthy),
                                    capture_output=True,text=True,timeout=6,check=True)
                return dict(json.loads(proc.stdout))
            rows=run('no')
            self.assertIn('failed (ENOTFOUND getaddrinfo '+SERVER+')',rows['DNS FRP server '+SERVER])
            self.assertIn('203.0.113.12',rows['DNS Host Manager '+cfg['manager']])
            self.assertRegex(rows['loopback /'],r'HTTP 200, identity matched \(pass\) \[\d+ ms\]')
            self.assertIn('HTTP 503, identity matched (fail)',rows['public /'])
            self.assertIn('body exceeds limit',rows['public /node/info'])
            self.assertIn('HTTP 200, JSON object (pass)',rows['loopback /node/info'])
            self.assertIn('WRONG identity (fail)',run('yes')['loopback /'])
            self.assertIn('WRONG identity (fail)',run('object')['loopback /'])
            # Exercise one complete operator snapshot and repeat it with a timeout only inside FRPC.
            outer=self.node._replace(name='podman',image='nosana/podman:1.1.2')
            for proxy_timeout in (False,True):
                def capture(cmd, **kwargs):
                    if 'inspect' in cmd:
                        return 0,'{"custom-bridge":{"IPAddress":"192.0.2.20"}}'
                    if 'nslookup' in cmd:
                        return 0,'Server: 192.0.2.53\nAddress: 192.0.2.53:53\n'
                    if cmd[-1]=='/etc/hosts':
                        return 0,''
                    if 'awk' in cmd:
                        return 0,route(WALLET_A)
                    if 'cat' in cmd:
                        return 0,'nameserver 192.0.2.53\n'
                    if 'getent' in cmd:
                        return (124,'') if proxy_timeout and cmd[-1]==SERVER else (0,'192.0.2.20 test\n')
                    if 'curl' in cmd:
                        return 0,json.dumps(WALLET_A)+'\n200'
                    if 'node' in cmd:
                        return 0,json.dumps(list(run('no','yes').items()))
                    self.fail(cmd)
                report=io.StringIO()
                with patch.dict(self.mod,inventory=lambda c:[outer] if c==['docker'] else [self.node,self.proxy],
                                capture=capture,read_logs=lambda *args:('start proxy success','captured')):
                    with contextlib.redirect_stdout(report):
                        self.mod['report']()
                snapshot=report.getvalue()
                for row in ['FRPC to node /: HTTP 200, identity matched','node loopback /: HTTP 200, identity matched',
                            'node public /: HTTP 200, identity matched','node public /node/info: HTTP 200, JSON object',
                            'node loopback /node/info: HTTP 200, JSON object']:
                    self.assertIn(row+' (pass)',snapshot)
                self.assertIn('node DNS FRP server '+SERVER+': 203.0.113.12',snapshot)
                self.assertIn('FRPC DNS server '+SERVER+': '+('failed (exit 124, timeout)' if proxy_timeout else '192.0.2.20'),snapshot)
                self.assertEqual(snapshot.count('failed ('),int(proxy_timeout))

    def test_frpc_root_rejects_wrong_shape_and_non_success_http_even_with_matching_identity(self):
        valid=self.mod['config_route'](route(WALLET_A),WALLET_A)
        for body,status,expected in [({'address':WALLET_A},'200','WRONG identity (fail)'),
                                     (WALLET_A,'301','identity matched (fail)')]:
            def capture(args,**kwargs):
                if 'curl' in args:
                    return 0,json.dumps(body)+'\n'+status
                return 0,'192.0.2.12 test\n'
            with patch.dict(self.mod,capture=capture):
                result=self.mod['frp_checks']([],self.proxy,valid,self.node)
            self.assertTrue(any('FRPC to node /: HTTP '+status+', '+expected in line for line in result))


if __name__ == '__main__':
    unittest.main()
