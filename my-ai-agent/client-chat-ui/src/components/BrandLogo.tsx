import Image from 'next/image'

// Intrinsic size from the SVGs' viewBox (both versions are ~5.47:1); only the ratio
// matters, CSS sets the height.
const LOGO_WIDTH = 1807
const LOGO_HEIGHT = 330

// Official artwork from Palo Alto Networks' kit, never recoloured: the full-colour
// version in light mode and the kit's own white version in dark mode.
export function BrandLogo({ className = 'h-7' }: { className?: string }) {
  const shared = { width: LOGO_WIDTH, height: LOGO_HEIGHT, alt: 'Palo Alto Networks', unoptimized: true }
  return (
    <>
      <Image src="/brand/panw-logo.svg" {...shared} className={`${className} w-auto dark:hidden`} />
      <Image src="/brand/panw-logo-white.svg" {...shared} className={`${className} w-auto hidden dark:block`} />
    </>
  )
}
