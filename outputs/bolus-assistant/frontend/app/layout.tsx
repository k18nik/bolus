import type {Metadata,Viewport} from 'next';
import './globals.css';
import './entry.css';
export const metadata: Metadata={title:'Bolus — ваш дневник заботы',description:'Глюкоза, питание и инсулин. Всё важное в одном спокойном месте.',manifest:'/manifest.webmanifest',icons:{icon:'/icon.svg'},appleWebApp:{capable:true,statusBarStyle:'default',title:'Bolus'}};
export const viewport:Viewport={width:'device-width',initialScale:1,themeColor:'#f6f8fa'};
export default function RootLayout({children}:{children:React.ReactNode}){return <html lang="ru"><body>{children}</body></html>}
