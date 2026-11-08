import { useState } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import { useForm } from 'react-hook-form';
import { motion } from 'framer-motion';
import { useAuth } from '../context/AuthContext.jsx';
import { Button, Input } from '../components/ui.jsx';

export default function Login() {
  const { login } = useAuth();
  const navigate = useNavigate();
  const { register, handleSubmit, formState: { errors, isSubmitting } } = useForm();
  const [serverError, setServerError] = useState('');

  const onSubmit = async ({ email, password }) => {
    setServerError('');
    try {
      const user = await login(email, password);
      navigate(`/${user.role}`);
    } catch (e) {
      setServerError(e.response?.data?.error || 'Login failed');
    }
  };

  return (
    <div className="min-h-screen grid lg:grid-cols-2">
      <div className="hidden lg:flex flex-col justify-between p-12 bg-brand-600 text-white relative overflow-hidden">
        <div className="absolute -top-24 -right-24 w-96 h-96 rounded-full bg-white/10 blur-3xl" />
        <div className="font-bold text-2xl">CTMS</div>
        <div>
          <motion.h1 initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }}
            className="text-4xl font-extrabold leading-tight">
            Track your campus bus<br/>in real time.
          </motion.h1>
          <p className="mt-4 text-white/80 max-w-md">
            Live location, smart ETA and instant announcements for the
            University of Kashmir North Campus transport fleet.
          </p>
        </div>
        <div className="text-white/60 text-sm">Hazratbal · Sopore · Baramulla · Srinagar</div>
      </div>

      <div className="flex items-center justify-center p-6">
        <motion.div initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }}
          className="glass w-full max-w-md p-8">
          <h2 className="text-2xl font-bold">Welcome back</h2>
          <p className="text-slate-500 dark:text-slate-400 text-sm mt-1">Sign in to your account</p>

          <form onSubmit={handleSubmit(onSubmit)} className="mt-6 space-y-4">
            <Input label="Email" type="email" placeholder="you@ctms.uok.edu.in"
              {...register('email', { required: 'Email required' })}
              error={errors.email?.message} />
            <Input label="Password" type="password" placeholder="••••••••"
              {...register('password', { required: 'Password required' })}
              error={errors.password?.message} />
            {serverError && <div className="text-sm text-rose-500 bg-rose-500/10 rounded-lg px-3 py-2">{serverError}</div>}
            <Button type="submit" disabled={isSubmitting} className="w-full">
              {isSubmitting ? 'Signing in…' : 'Sign in'}
            </Button>
          </form>

          <div className="mt-5 text-sm text-slate-500 text-center">
            New student? <Link to="/register" className="text-brand-500 font-medium">Create an account</Link>
          </div>
          <div className="mt-6 text-xs text-slate-400 border-t border-slate-200 dark:border-white/10 pt-4">
            <div className="font-semibold mb-1">Demo accounts</div>
            admin@ctms.uok.edu.in · Admin@123<br/>
            driver1@ctms.uok.edu.in · Driver@123<br/>
            student1@ctms.uok.edu.in · Student@123
          </div>
        </motion.div>
      </div>
    </div>
  );
}
