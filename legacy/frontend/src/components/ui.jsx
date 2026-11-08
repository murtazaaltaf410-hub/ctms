import { motion } from 'framer-motion';

export const Card = ({ children, className = '', ...rest }) => (
  <motion.div
    initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }}
    transition={{ duration: 0.35 }}
    className={`glass p-5 ${className}`} {...rest}>
    {children}
  </motion.div>
);

export const Button = ({ children, variant = 'primary', className = '', ...rest }) => {
  const styles = {
    primary: 'bg-brand-600 hover:bg-brand-700 text-white',
    ghost: 'bg-transparent hover:bg-slate-200/60 dark:hover:bg-white/10',
    danger: 'bg-rose-600 hover:bg-rose-700 text-white',
    success: 'bg-emerald-600 hover:bg-emerald-700 text-white',
  }[variant];
  return (
    <button
      className={`px-4 py-2.5 rounded-xl font-medium transition-all active:scale-95
        disabled:opacity-50 disabled:cursor-not-allowed ${styles} ${className}`}
      {...rest}>
      {children}
    </button>
  );
};

export const Input = ({ label, error, ...rest }) => (
  <label className="block">
    {label && <span className="text-sm font-medium text-slate-600 dark:text-slate-300">{label}</span>}
    <input
      className="mt-1 w-full px-3.5 py-2.5 rounded-xl bg-white/70 dark:bg-white/5
        border border-slate-300 dark:border-white/10 outline-none
        focus:ring-2 focus:ring-brand-500 transition"
      {...rest} />
    {error && <span className="text-xs text-rose-500 mt-1 block">{error}</span>}
  </label>
);

export const Skeleton = ({ className = '' }) => <div className={`skeleton ${className}`} />;

const STATUS = {
  on_time:   { label: 'On time',   cls: 'bg-emerald-500/15 text-emerald-500' },
  delayed:   { label: 'Delayed',   cls: 'bg-amber-500/15 text-amber-500' },
  breakdown: { label: 'Breakdown', cls: 'bg-rose-500/15 text-rose-500' },
  completed: { label: 'Completed', cls: 'bg-slate-500/15 text-slate-400' },
  idle:      { label: 'Idle',      cls: 'bg-slate-500/15 text-slate-400' },
};
export const StatusBadge = ({ status }) => {
  const s = STATUS[status] || STATUS.idle;
  return <span className={`px-2.5 py-1 rounded-full text-xs font-semibold ${s.cls}`}>{s.label}</span>;
};

const OCC = {
  available: { label: 'Seats available', cls: 'text-emerald-500' },
  moderate:  { label: 'Moderately full', cls: 'text-amber-500' },
  full:      { label: 'Full',            cls: 'text-rose-500' },
};
export const OccupancyTag = ({ occupancy }) => {
  const o = OCC[occupancy] || OCC.available;
  return <span className={`text-xs font-semibold ${o.cls}`}>● {o.label}</span>;
};
