/** @type {import('tailwindcss').Config} */
export default {
  darkMode: 'class',
  content: ['./index.html', './src/**/*.{js,jsx}'],
  theme: {
    extend: {
      colors: {
        brand: {
          50:'#eef4ff',100:'#d9e6ff',200:'#bcd3ff',300:'#8eb5ff',
          400:'#598dff',500:'#3366ff',600:'#1f47e6',700:'#1838b4',
          800:'#1a3392',900:'#1b2f74',
        },
      },
      fontFamily: { sans: ['Inter','system-ui','sans-serif'] },
      keyframes: {
        shimmer: { '100%': { transform: 'translateX(100%)' } },
        pulseRing: { '0%':{transform:'scale(.8)',opacity:.6},'100%':{transform:'scale(2.4)',opacity:0} },
      },
      animation: { shimmer:'shimmer 1.5s infinite', pulseRing:'pulseRing 1.6s ease-out infinite' },
    },
  },
  plugins: [],
};
