import { useEffect, useMemo, useState } from 'react';
import { useForm } from 'react-hook-form';
import { motion, AnimatePresence } from 'framer-motion';
import { api } from '../api/client.js';
import { useSocket } from '../hooks/useSocket.js';
import { Card, Button, Input, Skeleton, StatusBadge, OccupancyTag } from '../components/ui.jsx';

const TABS = ['Overview', 'Fleet', 'Users', 'Audit'];

// Small dependency-free horizontal bar — keeps the bundle lean.
const Bar = ({ label, value, max, color = 'bg-brand-500' }) => (
  <div className="flex items-center gap-3 text-sm">
    <span className="w-28 shrink-0 capitalize text-slate-500 dark:text-slate-400">{label}</span>
    <div className="flex-1 h-2.5 rounded-full bg-slate-200/70 dark:bg-white/5 overflow-hidden">
      <motion.div className={`h-full ${color}`}
        initial={{ width: 0 }} animate={{ width: `${max ? (value / max) * 100 : 0}%` }}
        transition={{ duration: 0.6 }} />
    </div>
    <span className="w-8 text-right font-semibold tabular-nums">{value}</span>
  </div>
);

const Kpi = ({ label, value, loading }) => (
  <Card className="flex flex-col gap-1">
    <span className="text-xs uppercase tracking-wide text-slate-500 dark:text-slate-400">{label}</span>
    {loading
      ? <Skeleton className="h-8 w-16" />
      : <span className="text-3xl font-bold tabular-nums">{value}</span>}
  </Card>
);

export default function AdminDashboard() {
  const [tab, setTab] = useState('Overview');
  const [overview, setOverview] = useState(null);
  const [users, setUsers] = useState(null);
  const [logs, setLogs] = useState(null);
  const [buses, setBuses] = useState([]);
  const [err, setErr] = useState('');
  const socketRef = useSocket(true);

  const load = async () => {
    try {
      const [o, b] = await Promise.all([api.get('/admin/overview'), api.get('/buses')]);
      setOverview(o.data);
      setBuses(b.data.buses);
    } catch (e) { setErr(e.response?.data?.error || 'Failed to load dashboard'); }
  };

  useEffect(() => { load(); }, []);

  // Live fleet updates over the socket.
  useEffect(() => {
    const s = socketRef.current;
    if (!s) return;
    const onLoc = (p) => setBuses((prev) => prev.map((bus) =>
      bus.id === p.busId ? { ...bus, latitude: p.latitude, longitude: p.longitude, speed_kmh: p.speed } : bus));
    const onStatus = (p) => setBuses((prev) => prev.map((bus) =>
      bus.id === p.busId ? { ...bus, status: p.status ?? bus.status, occupancy: p.occupancy ?? bus.occupancy } : bus));
    s.on('bus:location', onLoc);
    s.on('bus:status', onStatus);
    return () => { s.off('bus:location', onLoc); s.off('bus:status', onStatus); };
  }, [socketRef, socketRef.current]);

  const loadUsers = async () => { try { setUsers((await api.get('/admin/users')).data.users); } catch { /* */ } };
  const loadLogs = async () => { try { setLogs((await api.get('/admin/audit?limit=100')).data.logs); } catch { /* */ } };

  useEffect(() => {
    if (tab === 'Users' && !users) loadUsers();
    if (tab === 'Audit' && !logs) loadLogs();
  }, [tab]); // eslint-disable-line react-hooks/exhaustive-deps

  const statusMax = useMemo(
    () => Math.max(1, ...(overview?.statusBreakdown || []).map((s) => s.c)), [overview]);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between flex-wrap gap-3">
        <div>
          <h1 className="text-2xl font-bold">Admin control center</h1>
          <p className="text-sm text-slate-500 dark:text-slate-400">UoK North Campus transport operations</p>
        </div>
        <div className="flex gap-1 p-1 rounded-xl bg-slate-200/60 dark:bg-white/5">
          {TABS.map((t) => (
            <button key={t} onClick={() => setTab(t)}
              className={`px-3.5 py-1.5 rounded-lg text-sm font-medium transition
                ${tab === t ? 'bg-white dark:bg-white/10 shadow' : 'text-slate-500 hover:text-slate-700 dark:hover:text-slate-200'}`}>
              {t}
            </button>
          ))}
        </div>
      </div>

      {err && <Card className="border border-rose-500/30 text-rose-500">{err}</Card>}

      <AnimatePresence mode="wait">
        <motion.div key={tab}
          initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}
          transition={{ duration: 0.25 }}>

          {tab === 'Overview' && (
            <div className="space-y-6">
              <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
                <Kpi label="Students" value={overview?.kpis.students} loading={!overview} />
                <Kpi label="Drivers" value={overview?.kpis.drivers} loading={!overview} />
                <Kpi label="Active buses" value={overview?.kpis.buses} loading={!overview} />
                <Kpi label="Routes" value={overview?.kpis.routes} loading={!overview} />
              </div>
              <div className="grid lg:grid-cols-2 gap-4">
                <Card>
                  <h3 className="font-semibold mb-4">Fleet status</h3>
                  <div className="space-y-3">
                    {(overview?.statusBreakdown || []).map((s) => (
                      <Bar key={s.status} label={s.status.replace('_', ' ')} value={s.c} max={statusMax} />
                    ))}
                    {!overview && <Skeleton className="h-24 w-full" />}
                  </div>
                </Card>
                <Card>
                  <h3 className="font-semibold mb-4">Recent logins</h3>
                  <div className="divide-y divide-slate-200/70 dark:divide-white/5">
                    {(overview?.recentLogins || []).map((l, i) => (
                      <div key={i} className="flex items-center justify-between py-2 text-sm">
                        <span>{l.full_name} <span className="text-xs text-slate-400 capitalize">· {l.role}</span></span>
                        <span className="text-xs text-slate-400">{new Date(l.created_at).toLocaleString()}</span>
                      </div>
                    ))}
                    {overview?.recentLogins?.length === 0 && (
                      <p className="text-sm text-slate-400 py-2">No logins recorded yet.</p>)}
                    {!overview && <Skeleton className="h-24 w-full" />}
                  </div>
                </Card>
              </div>
            </div>
          )}

          {tab === 'Fleet' && (
            <Card>
              <div className="flex items-center justify-between mb-4">
                <h3 className="font-semibold">Live fleet</h3>
                <span className="flex items-center gap-2 text-xs text-emerald-500">
                  <span className="w-2 h-2 rounded-full bg-emerald-500 animate-pulse" /> realtime
                </span>
              </div>
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead className="text-left text-slate-500 dark:text-slate-400">
                    <tr className="border-b border-slate-200/70 dark:border-white/5">
                      <th className="py-2 font-medium">Bus</th><th className="font-medium">Route</th>
                      <th className="font-medium">Status</th><th className="font-medium">Occupancy</th>
                      <th className="font-medium">Speed</th><th className="font-medium">Position</th>
                    </tr>
                  </thead>
                  <tbody>
                    {buses.map((b) => (
                      <tr key={b.id} className="border-b border-slate-100/70 dark:border-white/5">
                        <td className="py-2.5 font-medium">{b.label}</td>
                        <td className="text-slate-500">{b.route_code || '—'}</td>
                        <td><StatusBadge status={b.status} /></td>
                        <td><OccupancyTag occupancy={b.occupancy} /></td>
                        <td className="tabular-nums">{b.speed_kmh ? `${Math.round(b.speed_kmh)} km/h` : '—'}</td>
                        <td className="text-xs text-slate-400 tabular-nums">
                          {b.latitude ? `${(+b.latitude).toFixed(4)}, ${(+b.longitude).toFixed(4)}` : 'no signal'}
                        </td>
                      </tr>
                    ))}
                    {buses.length === 0 && (
                      <tr><td colSpan={6} className="py-6 text-center text-slate-400">No buses yet.</td></tr>)}
                  </tbody>
                </table>
              </div>
            </Card>
          )}

          {tab === 'Users' && (
            <div className="grid lg:grid-cols-3 gap-4">
              <div className="lg:col-span-2">
                <Card>
                  <h3 className="font-semibold mb-4">Users</h3>
                  <div className="overflow-x-auto">
                    <table className="w-full text-sm">
                      <thead className="text-left text-slate-500 dark:text-slate-400">
                        <tr className="border-b border-slate-200/70 dark:border-white/5">
                          <th className="py-2 font-medium">Name</th><th className="font-medium">Email</th>
                          <th className="font-medium">Role</th><th className="font-medium">Active</th><th></th>
                        </tr>
                      </thead>
                      <tbody>
                        {(users || []).map((u) => (
                          <tr key={u.id} className="border-b border-slate-100/70 dark:border-white/5">
                            <td className="py-2.5 font-medium">{u.full_name}</td>
                            <td className="text-slate-500">{u.email}</td>
                            <td className="capitalize">{u.role}</td>
                            <td>{u.is_active
                              ? <span className="text-emerald-500">●</span>
                              : <span className="text-rose-500">●</span>}</td>
                            <td className="text-right">
                              <Button variant="ghost" className="text-xs px-2.5 py-1"
                                onClick={async () => {
                                  await api.patch(`/admin/users/${u.id}/active`, { isActive: !u.is_active });
                                  loadUsers();
                                }}>
                                {u.is_active ? 'Disable' : 'Enable'}
                              </Button>
                            </td>
                          </tr>
                        ))}
                        {!users && <tr><td colSpan={5}><Skeleton className="h-24 w-full my-2" /></td></tr>}
                      </tbody>
                    </table>
                  </div>
                </Card>
              </div>
              <CreateDriverForm buses={buses} onCreated={loadUsers} />
            </div>
          )}

          {tab === 'Audit' && (
            <Card>
              <h3 className="font-semibold mb-4">Audit log</h3>
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead className="text-left text-slate-500 dark:text-slate-400">
                    <tr className="border-b border-slate-200/70 dark:border-white/5">
                      <th className="py-2 font-medium">When</th><th className="font-medium">Actor</th>
                      <th className="font-medium">Action</th><th className="font-medium">Entity</th><th className="font-medium">IP</th>
                    </tr>
                  </thead>
                  <tbody>
                    {(logs || []).map((l) => (
                      <tr key={l.id} className="border-b border-slate-100/70 dark:border-white/5">
                        <td className="py-2 text-xs text-slate-400 tabular-nums">{new Date(l.created_at).toLocaleString()}</td>
                        <td>{l.full_name || <span className="text-slate-400">system</span>}</td>
                        <td><code className="text-xs">{l.action}</code></td>
                        <td className="text-slate-500">{l.entity ? `${l.entity}#${l.entity_id ?? ''}` : '—'}</td>
                        <td className="text-xs text-slate-400">{l.ip_address || '—'}</td>
                      </tr>
                    ))}
                    {!logs && <tr><td colSpan={5}><Skeleton className="h-32 w-full my-2" /></td></tr>}
                  </tbody>
                </table>
              </div>
            </Card>
          )}
        </motion.div>
      </AnimatePresence>
    </div>
  );
}

function CreateDriverForm({ buses, onCreated }) {
  const { register, handleSubmit, reset, formState: { errors, isSubmitting } } = useForm();
  const [msg, setMsg] = useState('');
  const free = buses; // backend rejects a bus already assigned (unique constraint)

  const onSubmit = async (v) => {
    setMsg('');
    try {
      await api.post('/admin/drivers', {
        email: v.email, password: v.password, fullName: v.fullName,
        phone: v.phone, licenseNo: v.licenseNo,
        assignedBusId: v.assignedBusId ? Number(v.assignedBusId) : null,
      });
      setMsg('Driver created.');
      reset();
      onCreated?.();
    } catch (e) { setMsg(e.response?.data?.error || 'Could not create driver'); }
  };

  return (
    <Card>
      <h3 className="font-semibold mb-4">Add driver</h3>
      <div className="space-y-3">
        <Input label="Full name" {...register('fullName', { required: true })}
          error={errors.fullName && 'Required'} />
        <Input label="Email" type="email" {...register('email', { required: true })}
          error={errors.email && 'Required'} />
        <Input label="Password" type="password"
          {...register('password', { required: true, minLength: 8 })}
          error={errors.password && 'Min 8 characters'} />
        <Input label="License no." {...register('licenseNo', { required: true })}
          error={errors.licenseNo && 'Required'} />
        <Input label="Phone (optional)" {...register('phone')} />
        <label className="block">
          <span className="text-sm font-medium text-slate-600 dark:text-slate-300">Assign bus (optional)</span>
          <select {...register('assignedBusId')}
            className="mt-1 w-full px-3.5 py-2.5 rounded-xl bg-white/70 dark:bg-white/5
              border border-slate-300 dark:border-white/10 outline-none focus:ring-2 focus:ring-brand-500">
            <option value="">— none —</option>
            {free.map((b) => <option key={b.id} value={b.id}>{b.label}</option>)}
          </select>
        </label>
        <Button onClick={handleSubmit(onSubmit)} disabled={isSubmitting} className="w-full">
          {isSubmitting ? 'Creating…' : 'Create driver'}
        </Button>
        {msg && <p className="text-sm text-center text-slate-500">{msg}</p>}
      </div>
    </Card>
  );
}
