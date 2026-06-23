import { useNavigate, Link } from 'react-router-dom';
import { motion } from 'framer-motion';
import { useAuth } from '../context/AuthContext.jsx';
import { useTheme } from '../context/ThemeContext.jsx';
import { Button } from './ui.jsx';

export const Layout = ({ children }) => {
  const { user, logout } = useAuth();
  const { dark, toggle } = useTheme();
  const navigate = useNavigate();

  const home = user ? `/${user.role}` : '/login';

  return (
    <div className="min-h-screen">
      <header className="sticky top-0 z-20 backdrop-blur-xl bg-white/60 dark:bg-slate-950/60
        border-b border-slate-200 dark:border-white/10">
        <div className="max-w-7xl mx-auto px-4 h-16 flex items-center justify-between">
          <Link to={home} className="flex items-center gap-2.5">
            <div className="w-9 h-9 rounded-xl bg-brand-600 grid place-items-center text-white font-bold">C</div>
            <div className="leading-tight">
              <div className="font-bold">CTMS</div>
              <div className="text-[11px] text-slate-500 dark:text-slate-400">UoK North Campus</div>
            </div>
          </Link>
          <div className="flex items-center gap-2">
            <button onClick={toggle} title="Toggle theme"
              className="w-10 h-10 rounded-xl hover:bg-slate-200/60 dark:hover:bg-white/10 transition">
              {dark ? '☀️' : '🌙'}
            </button>
            {user && (
              <div className="flex items-center gap-3">
                <div className="text-right hidden sm:block">
                  <div className="text-sm font-medium">{user.fullName}</div>
                  <div className="text-[11px] text-slate-500 capitalize">{user.role}</div>
                </div>
                <Button variant="ghost" onClick={async () => { await logout(); navigate('/login'); }}>
                  Logout
                </Button>
              </div>
            )}
          </div>
        </div>
      </header>
      <motion.main
        initial={{ opacity: 0 }} animate={{ opacity: 1 }}
        className="max-w-7xl mx-auto px-4 py-6">
        {children}
      </motion.main>
    </div>
  );
};
