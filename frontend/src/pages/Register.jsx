import { useState } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import { useForm } from 'react-hook-form';
import { useAuth } from '../context/AuthContext.jsx';
import { Button, Input } from '../components/ui.jsx';

export default function Register() {
  const { register: signup } = useAuth();
  const navigate = useNavigate();
  const { register, handleSubmit, formState: { errors, isSubmitting } } = useForm();
  const [serverError, setServerError] = useState('');
  const [ok, setOk] = useState(false);

  const onSubmit = async (values) => {
    setServerError('');
    try {
      await signup({
        email: values.email, password: values.password, fullName: values.fullName,
        phone: values.phone, enrollmentNo: values.enrollmentNo,
        department: values.department, semester: values.semester ? Number(values.semester) : undefined,
      });
      setOk(true);
      setTimeout(() => navigate('/login'), 1200);
    } catch (e) {
      setServerError(e.response?.data?.error || 'Registration failed');
    }
  };

  return (
    <div className="min-h-screen grid place-items-center p-6">
      <div className="glass w-full max-w-lg p-8">
        <h2 className="text-2xl font-bold">Create student account</h2>
        <p className="text-slate-500 dark:text-slate-400 text-sm mt-1">University of Kashmir North Campus</p>

        {ok ? (
          <div className="mt-6 text-emerald-500 bg-emerald-500/10 rounded-xl px-4 py-3">
            Account created! Redirecting to login…
          </div>
        ) : (
          <form onSubmit={handleSubmit(onSubmit)} className="mt-6 grid sm:grid-cols-2 gap-4">
            <Input label="Full name" {...register('fullName', { required: 'Required' })}
              error={errors.fullName?.message} />
            <Input label="Enrollment No." {...register('enrollmentNo', { required: 'Required' })}
              error={errors.enrollmentNo?.message} />
            <Input label="Email" type="email" {...register('email', { required: 'Required' })}
              error={errors.email?.message} className="sm:col-span-2" />
            <Input label="Password" type="password"
              {...register('password', { required: 'Required', minLength: { value: 8, message: 'Min 8 chars' } })}
              error={errors.password?.message} />
            <Input label="Phone" {...register('phone')} />
            <Input label="Department" {...register('department')} />
            <Input label="Semester" type="number" {...register('semester')} />
            {serverError && <div className="sm:col-span-2 text-sm text-rose-500 bg-rose-500/10 rounded-lg px-3 py-2">{serverError}</div>}
            <Button type="submit" disabled={isSubmitting} className="sm:col-span-2 w-full">
              {isSubmitting ? 'Creating…' : 'Create account'}
            </Button>
          </form>
        )}
        <div className="mt-5 text-sm text-slate-500 text-center">
          Already have an account? <Link to="/login" className="text-brand-500 font-medium">Sign in</Link>
        </div>
      </div>
    </div>
  );
}
