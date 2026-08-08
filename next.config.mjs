/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'export',
  basePath: '/vllm-ascend-recipes',
  images: {
    unoptimized: true,
  },
  // Disable trailing slash for clean URLs matching upstream
  trailingSlash: false,
};

export default nextConfig;
